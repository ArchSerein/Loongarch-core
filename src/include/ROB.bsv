import Types::*;
import ProcTypes::*;
import CoreTypes::*;
import Vector::*;
import OoOTypes::*;

// ============================================================
// Reorder Buffer (ROB)
// Circular buffer with speculative epoch token checks
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
  Vector#(32, Reg#(RobStaticEntry)) staticEntries <- replicateM(mkRegU);
  Vector#(32, Reg#(RobExecStatus)) execStatus <- replicateM(mkRegU);
  Vector#(32, Reg#(RobMemInfo)) memInfo <- replicateM(mkRegU);
  Reg#(Bit#(32)) validMask <- mkReg(0);
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

  function RobStaticEntry staticFromEntry(RobEntry e);
    return RobStaticEntry{
      token: e.token,
      pc: e.pc,
      inst: e.inst,
      pDst: e.pDst,
      oldPdst: e.oldPdst,
      dst: e.dst,
      pSrc1: e.pSrc1,
      pSrc2: e.pSrc2,
      iType: e.iType,
      isBranch: e.isBranch,
      isStore: e.isStore,
      isCsr: e.isCsr,
      isTlb: e.isTlb,
      isSpecial: e.isSpecial
    };
  endfunction

  function RobExecStatus statusFromEntry(RobEntry e);
    return RobExecStatus{
      state: e.state,
      excp: e.excp,
      mispredict: e.mispredict,
      correctTarget: e.correctTarget
    };
  endfunction

  function RobMemInfo memFromEntry(RobEntry e);
    return RobMemInfo{
      vaddr: e.memVaddr,
      paddr: e.memPaddr,
      useCache: e.memUseCache,
      mask: e.memMask
    };
  endfunction

  function RobEntry assembleEntry(
      Bool valid,
      RobStaticEntry staticEntry,
      RobExecStatus status,
      RobMemInfo mem
  );
    return RobEntry{
      valid: valid,
      token: staticEntry.token,
      state: status.state,
      pc: staticEntry.pc,
      inst: staticEntry.inst,
      pDst: staticEntry.pDst,
      oldPdst: staticEntry.oldPdst,
      dst: staticEntry.dst,
      pSrc1: staticEntry.pSrc1,
      pSrc2: staticEntry.pSrc2,
      iType: staticEntry.iType,
      excp: status.excp,
      isBranch: staticEntry.isBranch,
      isStore: staticEntry.isStore,
      isCsr: staticEntry.isCsr,
      isTlb: staticEntry.isTlb,
      isSpecial: staticEntry.isSpecial,
      mispredict: status.mispredict,
      correctTarget: status.correctTarget,
      memVaddr: mem.vaddr,
      memPaddr: mem.paddr,
      memUseCache: mem.useCache,
      memMask: mem.mask
    };
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    Bool doClear = clearReq;
    Bool doFlush = isValid(flushReq) && !doClear;
    Bool doEnq = isValid(enqReq) && !doFlush && !doClear;
    Bool doDeq = deqReq && !doClear;

    // Process entry writes.  Enqueue writes all three arrays; completion ports
    // only touch execStatus or memInfo, so static metadata is not rewritten.
    for (Integer i = 0; i < 32; i = i + 1) begin
      Bit#(5) idx = fromInteger(i);
      if (doEnq && tail == idx) begin
        RobEntry e = fromMaybe(?, enqReq);
        staticEntries[idx] <= staticFromEntry(e);
        execStatus[idx] <= statusFromEntry(e);
        memInfo[idx] <= memFromEntry(e);
      end else begin
        RobStaticEntry staticEntry = staticEntries[idx];
        RobExecStatus status = execStatus[idx];
        RobMemInfo mem = memInfo[idx];
        Bool valid = validMask[idx] == 1;
        Bool statusModified = False;
        Bool memModified = False;

        for (Integer p = 0; p < 4; p = p + 1) begin
          if (updateReqs[p] matches tagged Valid .req &&& tpl_1(req).index == idx &&
              valid && sameRobToken(staticEntry.token, tpl_1(req))) begin
            status.state = tpl_2(req);
            statusModified = True;
          end
        end
        if (updateExcpReq matches tagged Valid .req &&& tpl_1(req).index == idx &&
            valid && sameRobToken(staticEntry.token, tpl_1(req))) begin
          status.excp = tpl_2(req);
          statusModified = True;
        end
        if (updateBranchReq matches tagged Valid .req &&& tpl_1(req).index == idx &&
            valid && sameRobToken(staticEntry.token, tpl_1(req))) begin
          status.mispredict = tpl_2(req);
          status.correctTarget = tpl_3(req);
          statusModified = True;
        end
        if (updateMemInfoReq matches tagged Valid .req &&& tpl_1(req).index == idx &&
            valid && sameRobToken(staticEntry.token, tpl_1(req))) begin
          mem.vaddr = tpl_2(req);
          mem.paddr = tpl_3(req);
          mem.useCache = tpl_4(req);
          mem.mask = tpl_5(req);
          memModified = True;
        end

        if (statusModified) begin
          execStatus[idx] <= status;
        end
        if (memModified) begin
          memInfo[idx] <= mem;
        end
      end
    end

    // Update pointers and valid bits.
    if (doClear) begin
      validMask <= 0;
      headPtr <= 0;
      tail <= 0;
      count <= 0;
      epoch <= epoch + 1;
    end else if (doFlush) begin
      let tag = fromMaybe(?, flushReq);
      Bit#(5) flushAge = tag - headPtr;
      Bit#(32) keepMask = 0;

      for (Integer i = 0; i < 32; i = i + 1) begin
        Bit#(5) idx = fromInteger(i);
        Bit#(5) entryAge = idx - headPtr;
        Bool keep = validMask[idx] == 1 && entryAge <= flushAge &&
          !(doDeq && idx == headPtr);
        keepMask[idx] = pack(keep);
      end

      Bit#(5) effectiveHead = doDeq ? nextPtr(headPtr) : headPtr;
      validMask <= keepMask;
      tail <= nextPtr(tag);
      headPtr <= effectiveHead;
      count <= zeroExtend(tag - headPtr) + (doDeq ? 0 : 1);
      epoch <= epoch + 1;
    end else begin
      Bit#(5) nextHead = headPtr;
      Bit#(5) nextTail = tail;
      Bit#(6) nextCount = count;
      Bit#(32) nextValidMask = validMask;

      if (doEnq) begin
        nextValidMask[tail] = 1;
        nextTail = nextPtr(tail);
        nextCount = nextCount + 1;
      end
      if (doDeq) begin
        nextValidMask[headPtr] = 0;
        nextHead = nextPtr(headPtr);
        nextCount = nextCount - 1;
      end

      validMask <= nextValidMask;
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
    return assembleEntry(validMask[headPtr] == 1,
      staticEntries[headPtr], execStatus[headPtr], memInfo[headPtr]);
  endmethod

  method RobTag headTag = headPtr;

  method IType headIType;
    return (count != 0) ? staticEntries[headPtr].iType : Alu;
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
    return count != 0 && tagInWindow(token.index) && validMask[token.index] == 1 &&
           sameRobToken(staticEntries[token.index].token, token);
  endmethod

  method Action flushAfter(RobTag tag);
    flushReq <= tagged Valid tag;
  endmethod

  method Action clear;
    clearReq <= True;
  endmethod
endmodule
