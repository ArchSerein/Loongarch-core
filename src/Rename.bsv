package Rename;

import Types::*;
import ProcTypes::*;
import Fifo::*;
import CoreTypes::*;
import OoOTypes::*;
import PRF::*;
import RAT::*;
import FreeList::*;
import ROB::*;

// RN Stage: Rename -- RAT lookup, FreeList alloc, ROB enq.
function Bool renameNeedsFree(D2R r);
  return !r.excp.valid && isValid(normalizeReg(r.dInst.dst));
endfunction

function Action doRenameBody(
    Fifo#(2, D2R) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    RAT rat,
    FreeList freeList,
    PRF prf,
    ROB rob
);
  action
    let r = d2rnFifo.first;
    d2rnFifo.deq;

    DecodedInst dInst = r.dInst;
    ExcpInfo excp = r.excp;

    // Query RAT for source physical registers.
    PIndx pSrc1 = 0;
    PIndx pSrc2 = 0;
    if (dInst.src1 matches tagged Valid .s1) pSrc1 = rat.lookup(s1);
    if (dInst.src2 matches tagged Valid .s2) pSrc2 = rat.lookup(s2);

    // Allocate destination physical register.
    PIndx pDst = 0;
    PIndx oldPdst = 0;
    Maybe#(RIndx) normDst = normalizeReg(dInst.dst);
    if (!excp.valid &&& normDst matches tagged Valid .d) begin
      pDst = freeList.first;
      freeList.deq;
      oldPdst = rat.lookup(d);
      rat.update(d, pDst);
      prf.clearReady(pDst);
    end

    IType iType = dInst.iType;
    Bool brFlag = isBranch(iType);

    RobTag robTag = rob.enqTag;
    rob.enq(RobEntry{
      valid: True,
      state: RobIssued,
      pc: r.pc,
      inst: r.inst,
      pDst: (pDst == 0) ? tagged Invalid : tagged Valid pDst,
      oldPdst: (oldPdst == 0) ? tagged Invalid : tagged Valid oldPdst,
      dst: normDst,
      pSrc1: pSrc1,
      pSrc2: pSrc2,
      iType: iType,
      excp: excp,
      isBranch: brFlag,
      isStore: isStore(iType),
      isCsr: isCsr(iType),
      isTlb: isTlb(iType),
      isSpecial: isSpecial(iType),
      mispredict: False,
      correctTarget: r.pc + 4,
      memVaddr: 0,
      memPaddr: 0
    });

    if (brFlag) begin
      rat.checkpoint(robTag);
      freeList.checkpoint(robTag);
    end

    rn2diFifo.enq(RenamedInst{
      pc: r.pc,
      predPc: r.predPc,
      inst: r.inst,
      dInst: dInst,
      pSrc1: pSrc1,
      pSrc2: pSrc2,
      pDst: pDst,
      oldPdst: oldPdst,
      robTag: robTag,
      isBranch: brFlag,
      excp: excp
    });
  endaction
endfunction

endpackage
