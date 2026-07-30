package Dispatch;

import Types::*;
import ProcTypes::*;
import Fifo::*;
import OoOTypes::*;
import CoreTypes::*;
import PRF::*;
import ResStation::*;

function RSOperandState makeOperandState(
    PIndx pSrc1,
    PIndx pSrc2,
    Bool src1Ready,
    Bool src2Ready,
    Data vj,
    Data vk
);
  return RSOperandState{
    qj: src1Ready ? tagged Invalid : tagged Valid pSrc1,
    qk: src2Ready ? tagged Invalid : tagged Valid pSrc2,
    vj: vj,
    vk: vk
  };
endfunction

function Action doDispatchAluBody(
    Fifo#(2, RenamedInst) rn2diFifo,
    PRF prf,
    AluRS aluRS
);
  action
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
    Bool src1Ready = prf.isReady(rInst.pSrc1);
    Bool src2Ready = prf.isReady2(rInst.pSrc2);
    let entry = AluIssueEntry{
      payload: AluRSPayload{
        iType: rInst.dInst.iType,
        aluFunc: rInst.dInst.aluFunc,
        brFunc: rInst.dInst.brFunc,
        pDst: (rInst.pDst == 0) ? tagged Invalid : tagged Valid rInst.pDst,
        robTag: rInst.robTag,
        token: rInst.token,
        imm: rInst.dInst.imm,
        pc: rInst.pc,
        predPc: rInst.predPc
      },
      operands: makeOperandState(rInst.pSrc1, rInst.pSrc2, src1Ready, src2Ready,
        prf.rd1(rInst.pSrc1), prf.rd2(rInst.pSrc2))
    };
    aluRS.enq(entry);
  endaction
endfunction

function Action doDispatchMulDivBody(
    Fifo#(2, RenamedInst) rn2diFifo,
    PRF prf,
    MulDivRS muldivRS
);
  action
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
    Bool src1Ready = prf.isReady(rInst.pSrc1);
    Bool src2Ready = prf.isReady2(rInst.pSrc2);
    let entry = MulDivIssueEntry{
      payload: MulDivRSPayload{
        iType: rInst.dInst.iType,
        muldivFunc: rInst.dInst.muldivFunc,
        pDst: (rInst.pDst == 0) ? tagged Invalid : tagged Valid rInst.pDst,
        robTag: rInst.robTag,
        token: rInst.token
      },
      operands: makeOperandState(rInst.pSrc1, rInst.pSrc2, src1Ready, src2Ready,
        prf.rd1(rInst.pSrc1), prf.rd2(rInst.pSrc2))
    };
    muldivRS.enq(entry);
  endaction
endfunction

function Action doDispatchMemBody(
    Fifo#(2, RenamedInst) rn2diFifo,
    PRF prf,
    MemRS memRS
);
  action
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
    Bool isSt = isStore(rInst.dInst.iType);
    Bool isLd = isLoad(rInst.dInst.iType);
    Bool src1Ready = prf.isReady(rInst.pSrc1);
    Bool src2Ready = prf.isReady2(rInst.pSrc2);
    let entry = MemIssueEntry{
      payload: MemRSPayload{
        iType: rInst.dInst.iType,
        pDst: (rInst.pDst == 0) ? tagged Invalid : tagged Valid rInst.pDst,
        robTag: rInst.robTag,
        token: rInst.token,
        imm: rInst.dInst.imm,
        mask: rInst.dInst.mask,
        cacheOp: rInst.dInst.cacheOp,
        isStore: isSt,
        isLoad: isLd
      },
      operands: makeOperandState(rInst.pSrc1, rInst.pSrc2, src1Ready, src2Ready,
        prf.rd1(rInst.pSrc1), prf.rd2(rInst.pSrc2))
    };
    memRS.enq(entry);
  endaction
endfunction

function Action doDispatchSpecialBody(Fifo#(2, RenamedInst) rn2diFifo);
  action
    // CSR/TLB/special/exception: not dispatched to RS, just pass through.
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
  endaction
endfunction

endpackage
