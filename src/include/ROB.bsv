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
  method RobToken enqToken;          // next dynamic instruction token
  method SpecEpoch currentEpoch;     // current speculative epoch
  method Action enq(RobEntry e);     // insert at tail
  method RobEntry head;              // peek head entry (CM)
  method RobTag headTag;             // current head tag
  method IType headIType;            // head entry's iType (unguarded, for issue blocking)
  method Action deq;                 // advance head (CM)
  method Bool headValid;             // head slot occupied
  method Bool notFull;               // space available
  method Action updateALU(RobToken token, RobState state);
  method Action updateMul(RobToken token, RobState state);
  method Action updateDiv(RobToken token, RobState state);
  method Action updateMem(RobToken token, RobState state);
  method Action updateExcp(RobToken token, ExcpInfo excp);
  method Action updateBranch(RobToken token, Bool mispred, Addr target);
  method Action updateMemInfo(RobToken token, Addr vaddr, Addr paddr, Bool useCache, Maybe#(ByteMask) mask);
  method Bool tokenAlive(RobToken token);
  method Action flushAfter(RobTag tag);  // invalidate entries after tag
  method Action clear;               // full reset
endinterface

module mkROB(ROB);
  Vector#(32, Reg#(RobEntry)) entries <- replicateM(mkRegU);
  Reg#(Bit#(5)) headPtr <- mkReg(0);
  Reg#(Bit#(5)) tail <- mkReg(0);
  Reg#(Bit#(6)) count <- mkReg(0);
  Reg#(SpecEpoch) epoch <- mkReg(0);

  Wire#(Maybe#(RobEntry)) enqReq <- mkDWire(tagged Invalid);
  Wire#(Bool) deqReq <- mkDWire(False);
  // Each execution pipeline has an independent ROB completion port.  A single
  // DWire here would serialize otherwise independent writebacks.
  Vector#(4, Wire#(Maybe#(Tuple2#(RobToken, RobState)))) updateReqs <-
    replicateM(mkDWire(tagged Invalid));
  Wire#(Maybe#(Tuple2#(RobToken, ExcpInfo))) updateExcpReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(Tuple3#(RobToken, Bool, Addr))) updateBranchReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(Tuple5#(RobToken, Addr, Addr, Bool, Maybe#(ByteMask)))) updateMemInfoReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobTag)) flushReq <- mkDWire(tagged Invalid);
  Wire#(Bool) clearReq <- mkDWire(False);

  Bit#(5) maxIndex = 31;
  Bit#(6) depth = 32;

  function Bit#(5) nextPtr(Bit#(5) ptr);
    return (ptr == maxIndex) ? 0 : ptr + 1;
  endfunction

  function Bool tagInWindow(RobTag tag);
    Bit#(5) age = tag - headPtr;
    return zeroExtend(age) < count;
  endfunction

  function RobEntry invalidRobEntry;
    return RobEntry {
      valid: False, token: RobToken{index: 0, epoch: 0},
      state: RobIssued, pc: 0, inst: 0,
      pDst: tagged Invalid, oldPdst: tagged Invalid, dst: tagged Invalid,
      pSrc1: 0, pSrc2: 0, iType: Alu,
      excp: ExcpInfo{valid: False, ecode: 0, esubcode: 0, badv: 0},
      isBranch: False, isStore: False, isCsr: False,
      isTlb: False, isSpecial: False,
      mispredict: False, correctTarget: 0,
      memVaddr: 0, memPaddr: 0, memUseCache: False,
      memMask: tagged Invalid
    };
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
      // A flush makes younger entries unreachable by moving tail/count; they
      // need not be physically cleared and will be overwritten by later enqs.
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
        Bool newMemUseCache = e.memUseCache;
        Maybe#(ByteMask) newMemMask = e.memMask;
        Bool modified = False;

        for (Integer p = 0; p < 4; p = p + 1) begin
          if (updateReqs[p] matches tagged Valid .req &&& tpl_1(req).index == idx &&
              e.valid && sameRobToken(e.token, tpl_1(req))) begin
            newState = tpl_2(req);
            modified = True;
          end
        end
        if (updateExcpReq matches tagged Valid .req &&& tpl_1(req).index == idx &&
            e.valid && sameRobToken(e.token, tpl_1(req))) begin
          newExcp = tpl_2(req);
          modified = True;
        end
        if (updateBranchReq matches tagged Valid .req &&& tpl_1(req).index == idx &&
            e.valid && sameRobToken(e.token, tpl_1(req))) begin
          newMispredict = tpl_2(req);
          newCorrectTarget = tpl_3(req);
          modified = True;
        end
        if (updateMemInfoReq matches tagged Valid .req &&& tpl_1(req).index == idx &&
            e.valid && sameRobToken(e.token, tpl_1(req))) begin
          newMemVaddr = tpl_2(req);
          newMemPaddr = tpl_3(req);
          newMemUseCache = tpl_4(req);
          newMemMask = tpl_5(req);
          modified = True;
        end

        if (modified) begin
          entries[idx] <= RobEntry {
            valid: e.valid, token: e.token, state: newState, pc: e.pc, inst: e.inst,
            pDst: e.pDst, oldPdst: e.oldPdst,
            dst: e.dst,
            pSrc1: e.pSrc1, pSrc2: e.pSrc2,
            iType: e.iType, excp: newExcp,
            isBranch: e.isBranch, isStore: e.isStore, isCsr: e.isCsr,
            isTlb: e.isTlb, isSpecial: e.isSpecial,
            mispredict: newMispredict, correctTarget: newCorrectTarget,
            memVaddr: newMemVaddr, memPaddr: newMemPaddr,
            memUseCache: newMemUseCache, memMask: newMemMask
          };
        end
      end
    end

    // Update pointers
    if (doClear) begin
      headPtr <= 0;
      tail <= 0;
      count <= 0;
      epoch <= epoch + 1;
    end else if (doFlush) begin
      let tag = fromMaybe(?, flushReq);
      Bit#(5) effectiveHead = doDeq ? nextPtr(headPtr) : headPtr;
      tail <= nextPtr(tag);
      headPtr <= effectiveHead;
      count <= zeroExtend(tag - headPtr) + (doDeq ? 0 : 1);
      epoch <= epoch + 1;
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
  method RobToken enqToken = RobToken{index: tail, epoch: epoch};
  method SpecEpoch currentEpoch = epoch;
  method Bool notFull = count != depth;
  method Bool headValid = count != 0;

  method Action enq(RobEntry e) if (count != depth);
    enqReq <= tagged Valid e;
  endmethod

  method RobEntry head if (count != 0);
    return entries[headPtr];
  endmethod

  method RobTag headTag = headPtr;

  method IType headIType;
    return (count != 0) ? entries[headPtr].iType : Alu;
  endmethod

  method Action deq if (count != 0);
    deqReq <= True;
  endmethod

  method Action updateALU(RobToken token, RobState state);
    updateReqs[0] <= tagged Valid tuple2(token, state);
  endmethod

  method Action updateMul(RobToken token, RobState state);
    updateReqs[1] <= tagged Valid tuple2(token, state);
  endmethod

  method Action updateDiv(RobToken token, RobState state);
    updateReqs[2] <= tagged Valid tuple2(token, state);
  endmethod

  method Action updateMem(RobToken token, RobState state);
    updateReqs[3] <= tagged Valid tuple2(token, state);
  endmethod

  method Action updateExcp(RobToken token, ExcpInfo excp);
    updateExcpReq <= tagged Valid tuple2(token, excp);
  endmethod

  method Action updateBranch(RobToken token, Bool mispred, Addr target);
    updateBranchReq <= tagged Valid tuple3(token, mispred, target);
  endmethod

  method Action updateMemInfo(RobToken token, Addr vaddr, Addr paddr, Bool useCache, Maybe#(ByteMask) mask);
    updateMemInfoReq <= tagged Valid tuple5(token, vaddr, paddr, useCache, mask);
  endmethod

  method Bool tokenAlive(RobToken token);
    return count != 0 && tagInWindow(token.index) && entries[token.index].valid &&
           sameRobToken(entries[token.index].token, token);
  endmethod

  method Action flushAfter(RobTag tag);
    flushReq <= tagged Valid tag;
  endmethod

  method Action clear;
    clearReq <= True;
  endmethod
endmodule
