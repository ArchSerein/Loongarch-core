package Dispatch;

import Types::*;
import ProcTypes::*;
import Fifo::*;
import OoOTypes::*;
import CoreTypes::*;
import PRF::*;
import ResStation::*;

function Action doDispatchAluBody(
    Fifo#(2, RenamedInst) rn2diFifo,
    PRF prf,
    ResStation#(16) aluRS
);
  action
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
    Bool src1Ready = prf.isReady(rInst.pSrc1);
    Bool src2Ready = prf.isReady2(rInst.pSrc2);
    let entry = RSEntry{
      valid: True, iType: rInst.dInst.iType,
      aluFunc: rInst.dInst.aluFunc, muldivFunc: rInst.dInst.muldivFunc,
      brFunc: rInst.dInst.brFunc,
      qj: src1Ready ? tagged Invalid : tagged Valid rInst.pSrc1,
      qk: src2Ready ? tagged Invalid : tagged Valid rInst.pSrc2,
      vj: prf.rd1(rInst.pSrc1), vk: prf.rd2(rInst.pSrc2),
      pDst: (rInst.pDst == 0) ? tagged Invalid : tagged Valid rInst.pDst,
      robTag: rInst.robTag, token: rInst.token,
      imm: rInst.dInst.imm, pc: rInst.pc, predPc: rInst.predPc,
      mask: rInst.dInst.mask, cacheOp: rInst.dInst.cacheOp,
      isStore: False, isLoad: False
    };
    aluRS.enq(entry);
  endaction
endfunction

function Action doDispatchMulDivBody(
    Fifo#(2, RenamedInst) rn2diFifo,
    PRF prf,
    ResStation#(4) muldivRS
);
  action
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
    Bool src1Ready = prf.isReady(rInst.pSrc1);
    Bool src2Ready = prf.isReady2(rInst.pSrc2);
    let entry = RSEntry{
      valid: True, iType: rInst.dInst.iType,
      aluFunc: rInst.dInst.aluFunc, muldivFunc: rInst.dInst.muldivFunc,
      brFunc: rInst.dInst.brFunc,
      qj: src1Ready ? tagged Invalid : tagged Valid rInst.pSrc1,
      qk: src2Ready ? tagged Invalid : tagged Valid rInst.pSrc2,
      vj: prf.rd1(rInst.pSrc1), vk: prf.rd2(rInst.pSrc2),
      pDst: (rInst.pDst == 0) ? tagged Invalid : tagged Valid rInst.pDst,
      robTag: rInst.robTag, token: rInst.token,
      imm: rInst.dInst.imm, pc: rInst.pc, predPc: rInst.predPc,
      mask: rInst.dInst.mask, cacheOp: rInst.dInst.cacheOp,
      isStore: False, isLoad: False
    };
    muldivRS.enq(entry);
  endaction
endfunction

function Action doDispatchMemBody(
    Fifo#(2, RenamedInst) rn2diFifo,
    PRF prf,
    ResStation#(16) memRS
);
  action
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
    Bool isSt = isStore(rInst.dInst.iType);
    Bool isLd = isLoad(rInst.dInst.iType);
    let entry = RSEntry{
      valid: True, iType: rInst.dInst.iType,
      aluFunc: rInst.dInst.aluFunc, muldivFunc: rInst.dInst.muldivFunc,
      brFunc: rInst.dInst.brFunc,
      qj: prf.isReady(rInst.pSrc1) ? tagged Invalid : tagged Valid rInst.pSrc1,
      qk: prf.isReady2(rInst.pSrc2) ? tagged Invalid : tagged Valid rInst.pSrc2,
      vj: prf.rd1(rInst.pSrc1), vk: prf.rd2(rInst.pSrc2),
      pDst: (rInst.pDst == 0) ? tagged Invalid : tagged Valid rInst.pDst,
      robTag: rInst.robTag, token: rInst.token,
      imm: rInst.dInst.imm, pc: rInst.pc, predPc: rInst.predPc,
      mask: rInst.dInst.mask, cacheOp: rInst.dInst.cacheOp,
      isStore: isSt, isLoad: isLd
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
