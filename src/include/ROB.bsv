import Types::*;
import ProcTypes::*;
import CoreTypes::*;
import Vector::*;
import OoOTypes::*;

// ============================================================
// Reorder Buffer (ROB): 32-entry circular queue
// Ensures in-order commit, supports precise exceptions
// and branch mispredict recovery
// ============================================================

interface ROB;
  method RobTag enqTag;              // next tag to assign (tail)
  method Action enq(RobEntry e);     // insert at tail
  method RobEntry head;              // peek head entry (CM)
  method IType headIType;            // head entry's iType (unguarded, for issue blocking)
  method Action deq;                 // advance head (CM)
  method Bool headValid;             // head slot occupied
  method Bool notFull;               // space available
  method Action update(RobTag tag, RobState state);
  method Action updateExcp(RobTag tag, ExcpInfo excp);
  method Action updateBranch(RobTag tag, Bool mispred, Addr target);
  method Action updateMemInfo(RobTag tag, Addr vaddr, Addr paddr);
  method Action flushAfter(RobTag tag);  // invalidate entries after tag
  method Action clear;               // full reset
endinterface

module mkROB(ROB);
  Vector#(32, Reg#(RobEntry)) entries <- replicateM(mkRegU);
  Reg#(Bit#(5)) headPtr <- mkReg(0);
  Reg#(Bit#(5)) tail <- mkReg(0);
  Reg#(Bit#(6)) count <- mkReg(0);

  Wire#(Maybe#(RobEntry)) enqReq <- mkDWire(tagged Invalid);
  Wire#(Bool) deqReq <- mkDWire(False);
  Wire#(Maybe#(Tuple2#(RobTag, RobState))) updateReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(Tuple2#(RobTag, ExcpInfo))) updateExcpReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(Tuple3#(RobTag, Bool, Addr))) updateBranchReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(Tuple3#(RobTag, Addr, Addr))) updateMemInfoReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobTag)) flushReq <- mkDWire(tagged Invalid);
  Wire#(Bool) clearReq <- mkDWire(False);

  Bit#(5) maxIndex = 31;
  Bit#(6) depth = 32;

  function Bit#(5) nextPtr(Bit#(5) ptr);
    return (ptr == maxIndex) ? 0 : ptr + 1;
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    Bool doClear = clearReq;
    Bool doFlush = isValid(flushReq) && !doClear;
    Bool doEnq = isValid(enqReq) && !doFlush && !doClear;
    Bool doDeq = deqReq && !doClear;

    // Process entry writes: updates + enq (one write per entry max)
    for (Integer i = 0; i < 32; i = i + 1) begin
      Bit#(5) idx = fromInteger(i);

      if (doEnq && tail == idx) begin
        entries[idx] <= fromMaybe(?, enqReq);
      end else begin
        RobEntry e = entries[idx];
        RobState newState = e.state;
        ExcpInfo newExcp = e.excp;
        Bool newMispredict = e.mispredict;
        Addr newCorrectTarget = e.correctTarget;
        Addr newMemVaddr = e.memVaddr;
        Addr newMemPaddr = e.memPaddr;
        Bool modified = False;

        if (updateReq matches tagged Valid .req &&& tpl_1(req) == idx) begin
          newState = tpl_2(req);
          modified = True;
        end
        if (updateExcpReq matches tagged Valid .req &&& tpl_1(req) == idx) begin
          newExcp = tpl_2(req);
          modified = True;
        end
        if (updateBranchReq matches tagged Valid .req &&& tpl_1(req) == idx) begin
          newMispredict = tpl_2(req);
          newCorrectTarget = tpl_3(req);
          modified = True;
        end
        if (updateMemInfoReq matches tagged Valid .req &&& tpl_1(req) == idx) begin
          newMemVaddr = tpl_2(req);
          newMemPaddr = tpl_3(req);
          modified = True;
        end

        if (modified) begin
          entries[idx] <= RobEntry {
            valid: e.valid, state: newState, pc: e.pc, inst: e.inst,
            pDst: e.pDst, oldPdst: e.oldPdst,
            dst: e.dst,
            pSrc1: e.pSrc1, pSrc2: e.pSrc2,
            iType: e.iType, excp: newExcp,
            isBranch: e.isBranch, isStore: e.isStore, isCsr: e.isCsr,
            isTlb: e.isTlb, isSpecial: e.isSpecial,
            mispredict: newMispredict, correctTarget: newCorrectTarget,
            memVaddr: newMemVaddr, memPaddr: newMemPaddr
          };
        end
      end
    end

    // Update pointers
    if (doClear) begin
      headPtr <= 0;
      tail <= 0;
      count <= 0;
    end else if (doFlush) begin
      let tag = fromMaybe(?, flushReq);
      tail <= nextPtr(tag);
      count <= zeroExtend(tag - headPtr) + 1;
    end else begin
      Bit#(5) nextHead = headPtr;
      Bit#(5) nextTail = tail;
      Bit#(6) nextCount = count;

      if (doEnq) begin
        nextTail = nextPtr(tail);
        nextCount = nextCount + 1;
      end
      if (doDeq) begin
        nextHead = nextPtr(headPtr);
        nextCount = nextCount - 1;
      end

      headPtr <= nextHead;
      tail <= nextTail;
      count <= nextCount;
    end
  endrule

  method RobTag enqTag = tail;
  method Bool notFull = count != depth;
  method Bool headValid = count != 0;

  method Action enq(RobEntry e) if (count != depth);
    enqReq <= tagged Valid e;
  endmethod

  method RobEntry head if (count != 0);
    return entries[headPtr];
  endmethod

  method IType headIType;
    return (count != 0) ? entries[headPtr].iType : Alu;
  endmethod

  method Action deq if (count != 0);
    deqReq <= True;
  endmethod

  method Action update(RobTag tag, RobState state);
    updateReq <= tagged Valid tuple2(tag, state);
  endmethod

  method Action updateExcp(RobTag tag, ExcpInfo excp);
    updateExcpReq <= tagged Valid tuple2(tag, excp);
  endmethod

  method Action updateBranch(RobTag tag, Bool mispred, Addr target);
    updateBranchReq <= tagged Valid tuple3(tag, mispred, target);
  endmethod

  method Action updateMemInfo(RobTag tag, Addr vaddr, Addr paddr);
    updateMemInfoReq <= tagged Valid tuple3(tag, vaddr, paddr);
  endmethod

  method Action flushAfter(RobTag tag);
    flushReq <= tagged Valid tag;
  endmethod

  method Action clear;
    clearReq <= True;
  endmethod
endmodule
