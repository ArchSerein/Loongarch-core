package Commit;

`include "Autoconf.bsv"
`ifdef CONFIG_VSIM
`define CONFIG_WB_DEBUG
`define CONFIG_WB_DEBUG_INST
`endif
`ifdef CONFIG_FPGA
`define CONFIG_WB_DEBUG
`endif

import Types::*;
import ProcTypes::*;
import MemTypes::*;
import Decode::*;
import CsrFile::*;
import Mmu::*;
import Tlb::*;
import Fifo::*;
import Ehr::*;
import Vector::*;
import ICache::*;
import DCache::*;
import CoreTypes::*;
import BranchPredictor::*;
import FrontendFastPathQueue::*;
import BranchPredTypes::*;
import CoreFunc::*;
import OoOTypes::*;
import PRF::*;
import RAT::*;
import FreeList::*;
import ROB::*;
import ResStation::*;
import StoreBuf::*;
import DiffTypes::*;
`ifdef CONFIG_TRACE_PERFORMANCE
import Perf::*;
`endif
`ifdef CONFIG_DIFFTEST
import Difftest::*;
`endif

`include "CsrAddr.bsv"

typedef struct {
  Bit#(64) stableCounter;
  Data csrReadVal;
  Data tlbReqAsidVal;
  Bit#(5) tlbRdIndex;
  Data tlbWrIdx;
  Data tlbWrEhi;
  Data tlbWrElo0;
  Data tlbWrElo1;
  Bool llbctlKloVal;
  InterruptInfo interruptInfo;
} CommitCsrSnapshot deriving(Bits, Eq);

typedef struct {
  Bit#(6) ecode;
  Bit#(9) esubcode;
  Addr badv;
  Bool isInterrupt;
  Bit#(4) interruptNo;
} CommitTrapInfo deriving(Bits, Eq);

typedef struct {
  Bool retired;
  Bool deqRob;
  Bool waitTlb;
} CommitNormalResult deriving(Bits, Eq);

function Action doCollectCommitTLBBody(
    Reg#(CommitState) commitState,
    TlbArray tlb,
    ROB rob,
    CsrFile csrf
`ifdef CONFIG_DIFFTEST
    , Reg#(DiffArchCsrState) csrSnapReg
    , Vector#(32, Reg#(Data)) archRegs
    , Difftest difftest
`endif
`ifdef CONFIG_WB_DEBUG
    , Wire#(Bool) debugWsValidWire
    , Wire#(Addr) debugWbPcWire
`endif
);
  action
    let res <- tlb.resp;
    commitState <= CommitIdle;
    let head = rob.head;
    Bit#(5) wbTlbfillIndex = 0;
    Bool isTlbfill = !head.excp.valid && head.iType == Tlbfill;

`ifdef CONFIG_DIFFTEST
    DiffArchCsrState diffCsrSnap = csrSnapReg;
`endif

    if (!head.excp.valid) begin
      if (head.iType == Tlbsrch) begin
        Data srchResult = 0;
        if (res.ne) srchResult[`CSR_TLBIDX_NE] = 1'b1;
        else srchResult[`CSR_TLBIDX_INDEX] = res.ehi[`CSR_TLBIDX_INDEX];
        csrf.applyTlbsrchResult(srchResult);
      end else if (head.iType == Tlbrd) begin
        csrf.applyTlbrdResult(res.ne, res.ps, res.ehi, res.elo0, res.elo1, res.asid);
      end else if (head.iType == Tlbwr || head.iType == Tlbfill) begin
        csrf.commitTlbOp;
        if (isTlbfill) begin
          wbTlbfillIndex = truncate(res.ehi[`CSR_TLBIDX_INDEX]);
        end
      end
    end

`ifdef CONFIG_TRACE_PERFORMANCE
    inst_count();
`endif
    rob.deq;
`ifdef CONFIG_DIFFTEST
    // Difftest for TLB commit
    DiffArchCsrState diffCsr = diffCsrSnap;
    if (head.iType == Tlbsrch) begin
      Data srchResult = 0;
      if (res.ne) begin
        srchResult[`CSR_TLBIDX_NE] = 1'b1;
      end else begin
        srchResult[`CSR_TLBIDX_INDEX] = res.ehi[`CSR_TLBIDX_INDEX];
      end
      diffCsr = diffSnapshotAfterWriteFromState(
        diffCsrSnap, tagged Valid `CSR_TLBIDX, srchResult, False, 0, 0, head.pc, 0, False);
    end else if (head.iType == Tlbrd) begin
      diffCsr = diffSnapshotAfterTlbrdFromState(
        diffCsrSnap,
        res.ne, res.ps, res.ehi, res.elo0, res.elo1, res.asid
      );
    end
    Vector#(32, Data) gpr = ?;
    for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
    difftest.enqTrace(DiffTrace{
      commit: DiffCommit{
        valid: !head.excp.valid, pc: head.pc, nextPc: head.pc + 4,
        inst: head.inst, wen: False, wdest: 0, wdata: 0, skip: False,
        isTlbfill: isTlbfill,
        tlbfillIndex: wbTlbfillIndex
      },
      regs: DiffArchGRegState{gpr: gpr},
      csr: diffCsr,
      excp: DiffExcpEvent{excpValid: False, eret: False, interrupt: 0,
        exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
      store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
      load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
    });
`endif
`ifdef CONFIG_WB_DEBUG
    debugWsValidWire <= True;
    debugWbPcWire <= head.pc;
`endif
  endaction
endfunction

function Action takeCsrSnapshotBody(
`ifdef CONFIG_DIFFTEST
    Reg#(DiffArchCsrState) csrSnapReg,
`endif
    Reg#(CommitCsrSnapshot) commitCsrSnapReg,
    CsrFile csrf,
    ROB rob,
    Reg#(CommitState) commitState
);
  action
    DecodedInst dInst = decode(rob.head.inst);
    CsrIndx csrIdxForRd = fromMaybe(0, dInst.csr);
    InterruptInfo interruptInfo = csrf.interruptDetected;
`ifdef CONFIG_DIFFTEST
    csrSnapReg <= csrf.diffSnapshot;
`endif
    commitCsrSnapReg <= CommitCsrSnapshot{
      stableCounter: csrf.stableCounterValue,
      csrReadVal: csrf.rd(csrIdxForRd),
      tlbReqAsidVal: csrf.tlbWriteAsid,
      tlbRdIndex: csrf.tlbReadIndex,
      tlbWrIdx: csrf.tlbWriteIdx,
      tlbWrEhi: csrf.tlbWriteEhi,
      tlbWrElo0: csrf.tlbWriteElo0,
      tlbWrElo1: csrf.tlbWriteElo1,
      llbctlKloVal: csrf.llbctlKloValue,
      interruptInfo: interruptInfo
    };
    commitState <= interruptInfo.valid ? CommitInterruptReady : CommitReady;
  endaction
endfunction

function Action doCommitBody(
    ROB rob
`ifdef CONFIG_WB_DEBUG
    , Wire#(Bool) debugWsValidWire
    , Wire#(Addr) debugWbPcWire
`ifdef CONFIG_WB_DEBUG_INST
    , Wire#(Instruction) debugWbInstWire
`endif
`endif
);
  action
`ifdef CONFIG_WB_DEBUG
    let head = rob.head;
    debugWsValidWire <= True;
    debugWbPcWire <= head.pc;
`ifdef CONFIG_WB_DEBUG_INST
    debugWbInstWire <= head.inst;
`endif
`endif
  endaction
endfunction

function Action doCommitFlushAndRestore(
    ROB rob,
    RAT rat,
    FreeList freeList,
    TlbArray tlb,
    ICache iCache,
    DCache dCache,
    Addr redirectTarget,
    Bool clearLl,
    Reg#(Bool) if2WaitRefill,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    ResStation#(16) aluRS,
    ResStation#(4) muldivRS,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    Reg#(Bool) aluBusy,
    Reg#(Bool) mulInFlight,
    Reg#(Bool) divInFlight,
    Reg#(MemExecState) memState,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) accBusy,
    Reg#(Bool) accReqObsolete,
    BranchPredictor branchPred
);
  action
    iCache.squash;
    tlb.squashReq;
    tlb.squashFetchLookup;
    if (clearLl) begin
      dCache.clearReservation;
    end
    doFrontendRedirect(redirectTarget, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, if2WaitRefill, accBusy, accReqObsolete, branchPred);
    f1f2Fifo.clear;
    f2dFifo.clear;
    d2rnFifo.clear;
    rn2diFifo.clear;
    aluRS.clear;
    muldivRS.clear;
    memRS.clear;
    storeBuf.clearSpeculative;
    rob.clear;
    rat.restoreFromRetirement;
    freeList.restoreFromRetRAT(rat.allRetRAT);
    aluBusy <= False;
    mulInFlight <= False;
    divInFlight <= False;
    if (memState == MemUncacheWait || memState == MemCacheWait) begin
      memState <= MemIdle;
    end
  endaction
endfunction

function Action doCommitTrapAction(
    CommitTrapInfo trap,
    ROB rob,
    Reg#(CommitState) commitState,
    CsrFile csrf,
`ifdef CONFIG_DIFFTEST
    Reg#(DiffArchCsrState) csrSnapReg,
`endif
    RAT rat,
    FreeList freeList,
    TlbArray tlb,
    Reg#(Addr) pcReg,
    ICache iCache,
    DCache dCache,
    Reg#(Bool) if2WaitRefill,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    ResStation#(16) aluRS,
    ResStation#(4) muldivRS,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    Reg#(Bool) aluBusy,
    Reg#(Bool) mulInFlight,
    Reg#(Bool) divInFlight,
    Reg#(MemExecState) memState,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) accBusy,
    Reg#(Bool) accReqObsolete,
    BranchPredictor branchPred
`ifdef CONFIG_DIFFTEST
    , Difftest difftest
    , Vector#(32, Reg#(Data)) archRegs
`endif
);
  action
    let head = rob.head;
`ifdef CONFIG_DIFFTEST
    DiffArchCsrState diffCsrSnap = csrSnapReg;
`endif

    Addr exEntry <- csrf.raiseException(trap.ecode, trap.esubcode, head.pc, trap.badv);
    pcReg <= exEntry;
    doCommitFlushAndRestore(rob, rat, freeList, tlb, iCache, dCache, exEntry, False,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, aluBusy, mulInFlight,
      divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred);
    commitState <= CommitIdle;

`ifdef CONFIG_DIFFTEST
    Vector#(32, Data) gpr = ?;
    for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
    DiffArchCsrState diffCsr = diffSnapshotAfterWriteFromState(diffCsrSnap,
      tagged Invalid, 0, True, trap.ecode, trap.esubcode, head.pc, trap.badv, False);
    Data diffInterrupt = 0;
    Data diffException = 0;
    if (trap.isInterrupt) begin
      diffInterrupt = zeroExtend(trap.interruptNo);
    end else begin
      diffException = zeroExtend(trap.ecode);
    end
    difftest.enqTrace(DiffTrace{
      commit: DiffCommit{
        valid: False, pc: head.pc, nextPc: exEntry,
        inst: head.inst, wen: False, wdest: 0, wdata: 0, skip: False,
        isTlbfill: False, tlbfillIndex: 0
      },
      regs: DiffArchGRegState{gpr: gpr},
      csr: diffCsr,
      excp: DiffExcpEvent{excpValid: True, eret: False,
        interrupt: diffInterrupt, exception: diffException,
        exceptionPC: head.pc, exceptionInst: head.inst},
      store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
      load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
    });
`endif
  endaction
endfunction

function Action doCommitErtnAction(
    ROB rob,
    Reg#(CommitState) commitState,
    CsrFile csrf,
`ifdef CONFIG_DIFFTEST
    Reg#(DiffArchCsrState) csrSnapReg,
`endif
    Reg#(CommitCsrSnapshot) commitCsrSnapReg,
    RAT rat,
    FreeList freeList,
    TlbArray tlb,
    Reg#(Addr) pcReg,
    ICache iCache,
    DCache dCache,
    Reg#(Bool) if2WaitRefill,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    ResStation#(16) aluRS,
    ResStation#(4) muldivRS,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    Reg#(Bool) aluBusy,
    Reg#(Bool) mulInFlight,
    Reg#(Bool) divInFlight,
    Reg#(MemExecState) memState,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) accBusy,
    Reg#(Bool) accReqObsolete,
    BranchPredictor branchPred
`ifdef CONFIG_DIFFTEST
    , Difftest difftest
    , Vector#(32, Reg#(Data)) archRegs
`endif
);
  action
    let head = rob.head;
`ifdef CONFIG_DIFFTEST
    DiffArchCsrState diffCsrSnap = csrSnapReg;
    Bool llbctlKloVal = unpack(diffCsrSnap.llbctl[2]);
`else
    Bool llbctlKloVal = commitCsrSnapReg.llbctlKloVal;
`endif

    Bool clearLl = !llbctlKloVal;
    Addr era <- csrf.returnFromException;
    pcReg <= era;
    doCommitFlushAndRestore(rob, rat, freeList, tlb, iCache, dCache, era, clearLl,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, aluBusy, mulInFlight,
      divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred);
    commitState <= CommitIdle;

`ifdef CONFIG_TRACE_PERFORMANCE
    inst_count();
`endif

`ifdef CONFIG_DIFFTEST
    Vector#(32, Data) gpr = ?;
    for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
    DiffArchCsrState diffCsr = diffSnapshotAfterWriteFromState(diffCsrSnap,
      tagged Invalid, 0, False, 0, 0, head.pc, 0, True);
    difftest.enqTrace(DiffTrace{
      commit: DiffCommit{
        valid: True, pc: head.pc, nextPc: era,
        inst: head.inst, wen: False, wdest: 0, wdata: 0, skip: False,
        isTlbfill: False, tlbfillIndex: 0
      },
      regs: DiffArchGRegState{gpr: gpr},
      csr: diffCsr,
      excp: DiffExcpEvent{excpValid: False, eret: True,
        interrupt: 0,
        exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
      store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
      load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
    });
`endif
  endaction
endfunction

function Action doCommitRedirectAction(
    ROB rob,
    Reg#(CommitState) commitState,
    CsrFile csrf,
`ifdef CONFIG_DIFFTEST
    Reg#(DiffArchCsrState) csrSnapReg,
`endif
    RAT rat,
    FreeList freeList,
    TlbArray tlb,
    Reg#(Addr) pcReg,
    ICache iCache,
    DCache dCache,
    Reg#(Bool) if2WaitRefill,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    ResStation#(16) aluRS,
    ResStation#(4) muldivRS,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    Reg#(Bool) idleLock,
    Reg#(Bool) aluBusy,
    Reg#(Bool) mulInFlight,
    Reg#(Bool) divInFlight,
    Reg#(MemExecState) memState,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) accBusy,
    Reg#(Bool) accReqObsolete,
    BranchPredictor branchPred
`ifdef CONFIG_BSIM
    , PRF prf
    , Fifo#(2, CpuToHostData) toHostFifo
`endif
`ifdef CONFIG_DIFFTEST
    , Difftest difftest
    , Vector#(32, Reg#(Data)) archRegs
`endif
);
  action
    let head = rob.head;
`ifdef CONFIG_DIFFTEST
    DiffArchCsrState diffCsrSnap = csrSnapReg;
`endif

    if (head.excp.valid) begin
      Bit#(6) ecode = head.excp.ecode;
      Bit#(9) esubcode = head.excp.esubcode;
`ifdef CONFIG_BSIM
      if (ecode == `ECODE_SYS && esubcode == 1) begin
        Data exitCode = prf.rdDbg(rat.lookupRet(4));
        $display("this syscall 0x11, finish simulation");
        toHostFifo.enq(CpuToHostData{c2hType: ExitCode, data: truncate(exitCode)});
      end
`endif
      doCommitTrapAction(CommitTrapInfo{
          ecode: ecode, esubcode: esubcode, badv: head.excp.badv,
          isInterrupt: False, interruptNo: 0
        },
        rob, commitState, csrf,
`ifdef CONFIG_DIFFTEST
        csrSnapReg,
`endif
        rat, freeList, tlb, pcReg, iCache, dCache,
        if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
        aluRS, muldivRS, memRS, storeBuf, aluBusy, mulInFlight,
        divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
        fetchInflightValid, accBusy, accReqObsolete, branchPred
`ifdef CONFIG_DIFFTEST
        , difftest, archRegs
`endif
      );
    end else if (head.iType == Idle) begin
      idleLock <= True;
      pcReg <= head.pc + 4;
      doCommitFlushAndRestore(rob, rat, freeList, tlb, iCache, dCache, head.pc + 4, False,
        if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
        aluRS, muldivRS, memRS, storeBuf, aluBusy, mulInFlight,
        divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred);
`ifdef CONFIG_TRACE_PERFORMANCE
      inst_count();
`endif
      commitState <= CommitIdle;

`ifdef CONFIG_DIFFTEST
      Vector#(32, Data) gpr = ?;
      for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
      DiffArchCsrState diffCsr = diffCsrSnap;
      difftest.enqTrace(DiffTrace{
        commit: DiffCommit{
          valid: True, pc: head.pc, nextPc: head.pc + 4,
          inst: head.inst, wen: False, wdest: 0, wdata: 0, skip: False,
          isTlbfill: False, tlbfillIndex: 0
        },
        regs: DiffArchGRegState{gpr: gpr},
        csr: diffCsr,
        excp: DiffExcpEvent{excpValid: False, eret: False, interrupt: 0,
          exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
        store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
        load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
      });
`endif
    end else if (head.iType == Syscall || head.iType == Break) begin
      Bit#(6) ecode = (head.iType == Syscall) ? `ECODE_SYS : `ECODE_BRK;
      Bit#(9) esubcode = `ESUBCODE_NONE;
`ifdef CONFIG_BSIM
      if (head.iType == Syscall) begin
        Bit#(9) syscallEsubcode = (head.inst[14:0] == 17) ? 1 : `ESUBCODE_NONE;
        esubcode = syscallEsubcode;
        if (esubcode == 1) begin
          Data exitCode = prf.rdDbg(rat.lookupRet(4));
          $display("this syscall 0x11, finish simulation");
          toHostFifo.enq(CpuToHostData{c2hType: ExitCode, data: truncate(exitCode)});
        end
      end
`endif
      doCommitTrapAction(CommitTrapInfo{
          ecode: ecode, esubcode: esubcode, badv: head.pc,
          isInterrupt: False, interruptNo: 0
        },
        rob, commitState, csrf,
`ifdef CONFIG_DIFFTEST
        csrSnapReg,
`endif
        rat, freeList, tlb, pcReg, iCache, dCache,
        if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
        aluRS, muldivRS, memRS, storeBuf, aluBusy, mulInFlight,
        divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
        fetchInflightValid, accBusy, accReqObsolete, branchPred
`ifdef CONFIG_DIFFTEST
        , difftest, archRegs
`endif
      );
    end
  endaction
endfunction

function ActionValue#(CommitNormalResult) doCommitNormalSharedAction(
    ROB rob,
    CsrFile csrf,
`ifdef CONFIG_DIFFTEST
    Reg#(DiffArchCsrState) csrSnapReg,
`endif
    Reg#(CommitCsrSnapshot) commitCsrSnapReg,
    PRF prf,
    RAT rat,
    TlbArray tlb,
    Reg#(Addr) pcReg,
    ICache iCache,
    DCache dCache,
    Reg#(Bool) if2WaitRefill,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    ResStation#(16) aluRS,
    ResStation#(4) muldivRS,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    StoreForwardBuf#(16) committedStoreBuf,
    Reg#(Bool) aluBusy,
    Reg#(Bool) mulInFlight,
    Reg#(Bool) divInFlight,
    Reg#(MemExecState) memState,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) accBusy,
    Reg#(Bool) accReqObsolete,
    BranchPredictor branchPred
`ifdef CONFIG_DIFFTEST
    , Difftest difftest
    , Vector#(32, Reg#(Data)) archRegs
`endif
);
  actionvalue
    let head = rob.head;
    Bool retired = False;
    Bool deqRob = False;
    Bool waitTlb = False;

    DecodedInst dInst = decode(head.inst);
    CsrIndx csrIdxForRd = fromMaybe(0, dInst.csr);
    CommitCsrSnapshot commitCsrSnap = commitCsrSnapReg;
`ifdef CONFIG_DIFFTEST
    DiffArchCsrState diffCsrSnap = csrSnapReg;
    Data csrReadVal = csrRdFromSnapshot(diffCsrSnap, csrIdxForRd);
    Data tlbReqAsidVal = diffCsrSnap.asid;
    Bit#(5) tlbRdIndex = truncate(diffCsrSnap.tlbidx[`CSR_TLBIDX_INDEX]);
    Data tlbWrIdx = effectiveTlbIdxForWrite(diffCsrSnap.tlbidx, diffCsrSnap.estat);
    Data tlbWrEhi = diffCsrSnap.tlbehi;
    Data tlbWrElo0 = diffCsrSnap.tlbelo0;
    Data tlbWrElo1 = diffCsrSnap.tlbelo1;
`else
    Data csrReadVal = commitCsrSnap.csrReadVal;
    Data tlbReqAsidVal = commitCsrSnap.tlbReqAsidVal;
    Bit#(5) tlbRdIndex = commitCsrSnap.tlbRdIndex;
    Data tlbWrIdx = commitCsrSnap.tlbWrIdx;
    Data tlbWrEhi = commitCsrSnap.tlbWrEhi;
    Data tlbWrElo0 = commitCsrSnap.tlbWrElo0;
    Data tlbWrElo1 = commitCsrSnap.tlbWrElo1;
`endif
    Bit#(64) stableCounter = commitCsrSnap.stableCounter;

    Data cmRVal1 = prf.rd3(head.pSrc1);
    Data cmRVal2 = prf.rd4(head.pSrc2);
    StoreBufEntry commitStoreEntry = ?;

    if (isTlb(head.iType)) begin
      Data rVal1 = cmRVal1;
      Data rVal2 = cmRVal2;
      TlbOp op = TlbOpSearch;
      if (head.iType == Tlbrd) op = TlbOpRead;
      else if (head.iType == Tlbwr) op = TlbOpWrite;
      else if (head.iType == Tlbfill) op = TlbOpFill;
      else if (head.iType == Invtlb) op = TlbOpInv;
      Data tlbReqAsid = (head.iType == Invtlb) ? rVal1 : tlbReqAsidVal;
      tlb.req(TlbReq{
        op: op,
        tlbidx: (head.iType == Tlbrd) ? zeroExtend(tlbRdIndex) : tlbWrIdx,
        invOp: truncate(fromMaybe(0, dInst.imm)),
        ehi: tlbWrEhi,
        elo0: tlbWrElo0,
        elo1: tlbWrElo1,
        asid: tlbReqAsid,
        va: (head.iType == Invtlb) ? rVal2 : rVal1
      });
      waitTlb = True;
    end else if (isCsr(head.iType)) begin
      Data rVal1 = cmRVal1;
      Data rVal2 = cmRVal2;

      Data csrVal = ?;
      if (head.iType == RdTimeL) begin
        csrVal = truncate(stableCounter);
      end else if (head.iType == RdTimeH) begin
        csrVal = truncateLSB(stableCounter);
      end else begin
        csrVal = csrReadVal;
      end

`ifdef CONFIG_DIFFTEST
      Bool wen = False;
      Data wdata = csrVal;
      Vector#(32, Data) gpr = ?;
      for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
      if (head.dst matches tagged Valid .dst &&& dst != 0) begin
        gpr[dst] = csrVal;
        wen = True;
      end
      Maybe#(CsrIndx) diffCsrIdx = tagged Invalid;
      Data diffCsrVal = csrVal;
      if (head.iType == Csrw) begin
        diffCsrIdx = dInst.csr;
        diffCsrVal = rVal1;
      end else if (head.iType == Csrxchg) begin
        diffCsrIdx = dInst.csr;
        diffCsrVal = (csrVal & (~rVal2)) | (rVal1 & rVal2);
      end
      DiffArchCsrState diffCsr = diffSnapshotAfterWriteFromState(diffCsrSnap,
        diffCsrIdx, diffCsrVal, False, 0, 0, head.pc, 0, False);
`endif

      Data csrWriteVal = csrVal;
      Bool csrDoWrite = False;
      if (head.iType == Csrw) begin
        csrWriteVal = rVal1;
        csrDoWrite = True;
        csrf.wr(dInst.csr, csrWriteVal);
      end else if (head.iType == Csrxchg) begin
        csrWriteVal = (csrVal & (~rVal2)) | (rVal1 & rVal2);
        csrDoWrite = True;
        csrf.wr(dInst.csr, csrWriteVal);
      end
      if (csrDoWrite) begin
        if (dInst.csr matches tagged Valid .csrIdx) begin
          if (csrIdx == `CSR_LLBCTL) begin
            if (unpack(csrWriteVal[1])) begin
              dCache.clearReservation;
            end
          end
        end
      end

      if (head.dst matches tagged Valid .dst &&& dst != 0) begin
        if (head.pDst matches tagged Valid .pd) begin
          prf.commitWrite(pd, csrVal);
          prf.setReadyCommit(pd);
          let csrWakeup = CDBMessage{tag: pd, value: csrVal, valid: True};
          aluRS.commitWakeup(csrWakeup);
          muldivRS.commitWakeup(csrWakeup);
          memRS.commitWakeup(csrWakeup);
        end
`ifdef CONFIG_DIFFTEST
        archRegs[dst] <= csrVal;
`endif
      end

      retired = True;
      deqRob = True;

`ifdef CONFIG_DIFFTEST
      difftest.enqTrace(DiffTrace{
        commit: DiffCommit{
          valid: True, pc: head.pc, nextPc: head.pc + 4,
          inst: head.inst, wen: wen, wdest: fromMaybe(0, head.dst),
          wdata: wdata, skip: False, isTlbfill: False, tlbfillIndex: 0
        },
        regs: DiffArchGRegState{gpr: gpr},
        csr: diffCsr,
        excp: DiffExcpEvent{excpValid: False, eret: False,
          interrupt: 0,
          exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
        store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
        load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
      });
`endif
    end else if (head.state == RobCompleted && head.iType != Ibar) begin
      if (head.iType == St) begin
        if (storeBuf.lookupEntry(head.token) matches tagged Valid .s) begin
          commitStoreEntry = s;
        end
        storeBuf.commit(head.token);
      end

      Bool wen = False;
      Data wdata = 0;
      if (head.dst matches tagged Valid .dst &&& dst != 0) begin
        if (head.pDst matches tagged Valid .pd) begin
          wdata = prf.rd5(pd);
        end
`ifdef CONFIG_DIFFTEST
        archRegs[dst] <= wdata;
`endif
        wen = True;
      end

      if (head.iType == Ll) begin
        csrf.setLlbit(True);
      end else if (head.iType == Sc) begin
        csrf.setLlbit(False);
      end

      retired = True;
      deqRob = True;

`ifdef CONFIG_DIFFTEST
      Vector#(32, Data) gpr = ?;
      for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
      if (head.dst matches tagged Valid .dst &&& dst != 0) begin
        gpr[dst] = wdata;
      end
      DiffArchCsrState diffCsr = diffCsrSnap;
      if (head.iType == Ll || head.iType == Sc) begin
        Data diffLlbctl = diffCsr.llbctl;
        diffLlbctl[0] = pack(head.iType == Ll);
        diffCsr.llbctl = diffLlbctl;
      end
      Addr commitNextPc = head.isBranch ? head.correctTarget : (head.pc + 4);
      Maybe#(DiffMemOp) diffMem = tagged Invalid;
      Maybe#(ByteMask) diffMemMask = head.memMask;
      if (head.iType == Ld || head.iType == Ll) begin
        diffMem = tagged Valid DiffMemOp{
          isLoad: True, isStore: False, isSc: False,
          paddr: head.memPaddr, vaddr: head.memVaddr, storeData: 0
        };
      end else if (head.iType == St) begin
        diffMem = tagged Valid DiffMemOp{
          isLoad: False, isStore: True, isSc: False,
          paddr: head.memPaddr, vaddr: head.memVaddr,
          storeData: commitStoreEntry.data
        };
      end else if (head.iType == Sc) begin
        ByteMask scMask = fromMaybe(5'b0, head.memMask);
        let scStorePkt = selectStoreData(cmRVal2, head.memVaddr[1:0], scMask[3:0]);
        diffMem = tagged Valid DiffMemOp{
          isLoad: False, isStore: True, isSc: True,
          paddr: head.memPaddr, vaddr: head.memVaddr,
          storeData: tpl_2(scStorePkt)
        };
      end
      DiffStoreEvent storeEvent = diffStoreEventOf(diffMem, head.iType, diffMemMask, wdata);
      DiffLoadEvent loadEvent = diffLoadEventOf(diffMem, head.iType, diffMemMask);
      difftest.enqTrace(DiffTrace{
        commit: DiffCommit{
          valid: True, pc: head.pc, nextPc: commitNextPc,
          inst: head.inst, wen: wen, wdest: fromMaybe(0, head.dst),
          wdata: wdata, skip: False,
          isTlbfill: False, tlbfillIndex: 0
        },
        regs: DiffArchGRegState{gpr: gpr},
        csr: diffCsr,
        excp: DiffExcpEvent{excpValid: False, eret: False,
          interrupt: 0,
          exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
        store: storeEvent,
        load: loadEvent
      });
`endif
    end

    return CommitNormalResult{retired: retired, deqRob: deqRob, waitTlb: waitTlb};
  endactionvalue
endfunction

function Action doCommitIbarAction(
    ROB rob,
    Reg#(CommitState) commitState,
`ifdef CONFIG_DIFFTEST
    Reg#(DiffArchCsrState) csrSnapReg,
`endif
    RAT rat,
    FreeList freeList,
    TlbArray tlb,
    Reg#(Addr) pcReg,
    ICache iCache,
    Reg#(Bool) if2WaitRefill,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    ResStation#(16) aluRS,
    ResStation#(4) muldivRS,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    Reg#(Bool) aluBusy,
    Reg#(Bool) mulInFlight,
    Reg#(Bool) divInFlight,
    Reg#(MemExecState) memState,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) accBusy,
    Reg#(Bool) accReqObsolete,
    BranchPredictor branchPred
`ifdef CONFIG_DIFFTEST
    , Difftest difftest
    , Vector#(32, Reg#(Data)) archRegs
`endif
);
  action
    let head = rob.head;
    Addr nextPc = head.pc + 4;

    pcReg <= nextPc;
    iCache.squash;
    tlb.squashFetchLookup;
    doFrontendRedirect(nextPc, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, if2WaitRefill, accBusy, accReqObsolete, branchPred);
    f1f2Fifo.clear;
    f2dFifo.clear;
    d2rnFifo.clear;
    rn2diFifo.clear;
    aluRS.clear;
    muldivRS.clear;
    memRS.clear;
    storeBuf.clearSpeculative;
    rob.clear;
    rat.restoreFromRetirement;
    freeList.restoreFromRetRAT(rat.allRetRAT);
    aluBusy <= False;
    mulInFlight <= False;
    divInFlight <= False;
    if (memState == MemUncacheWait || memState == MemCacheWait) begin
      memState <= MemIdle;
    end

`ifdef CONFIG_TRACE_PERFORMANCE
    inst_count();
`endif
    commitState <= CommitIdle;

`ifdef CONFIG_DIFFTEST
    Vector#(32, Data) gpr = ?;
    for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
    DiffArchCsrState diffCsr = csrSnapReg;
    difftest.enqTrace(DiffTrace{
      commit: DiffCommit{
        valid: True, pc: head.pc, nextPc: nextPc,
        inst: head.inst, wen: False, wdest: 0, wdata: 0, skip: False,
        isTlbfill: False, tlbfillIndex: 0
      },
      regs: DiffArchGRegState{gpr: gpr},
      csr: diffCsr,
      excp: DiffExcpEvent{excpValid: False, eret: False, interrupt: 0,
        exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
      store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
      load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
    });
`endif
  endaction
endfunction

function Action doCommitReclaimAction(
    ROB rob,
    Reg#(CommitState) commitState,
    CsrFile csrf,
`ifdef CONFIG_DIFFTEST
    Reg#(DiffArchCsrState) csrSnapReg,
`endif
    Reg#(CommitCsrSnapshot) commitCsrSnapReg,
    PRF prf,
    RAT rat,
    FreeList freeList,
    TlbArray tlb,
    Reg#(Addr) pcReg,
    ICache iCache,
    DCache dCache,
    Reg#(Bool) if2WaitRefill,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    ResStation#(16) aluRS,
    ResStation#(4) muldivRS,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    StoreForwardBuf#(16) committedStoreBuf,
    Reg#(Bool) aluBusy,
    Reg#(Bool) mulInFlight,
    Reg#(Bool) divInFlight,
    Reg#(MemExecState) memState,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) accBusy,
    Reg#(Bool) accReqObsolete,
    BranchPredictor branchPred
`ifdef CONFIG_DIFFTEST
    , Difftest difftest
    , Vector#(32, Reg#(Data)) archRegs
`endif
);
  action
    let head = rob.head;
    let result <- doCommitNormalSharedAction(rob, csrf,
`ifdef CONFIG_DIFFTEST
      csrSnapReg,
`endif
      commitCsrSnapReg, prf, rat, tlb, pcReg, iCache, dCache,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, committedStoreBuf, aluBusy,
      mulInFlight, divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred
`ifdef CONFIG_DIFFTEST
      , difftest, archRegs
`endif
    );

    if (result.retired) begin
      if (head.dst matches tagged Valid .dst &&& dst != 0) begin
        rat.updateRet(dst, fromMaybe(?, head.pDst));
      end
      if (head.oldPdst matches tagged Valid .old) begin
        freeList.enq(old);
      end
`ifdef CONFIG_TRACE_PERFORMANCE
      inst_count();
`endif
    end

    if (result.waitTlb) begin
      commitState <= CommitTLBWait;
    end else begin
      commitState <= CommitIdle;
    end

    if (result.deqRob) begin
      if (head.isBranch) begin
        Bool actualTaken = (head.iType == Br) ? (head.correctTarget != head.pc + 4) : True;
        CfiType cfiType = (head.iType == Br) ? CFI_COND :
                          ((head.iType == J) ? CFI_JAL : CFI_JALR);
        branchPred.commitHistory(actualTaken, head.correctTarget, cfiType);
      end
      rob.deq;
    end
  endaction
endfunction

function Action doCommitNoReclaimAction(
    ROB rob,
    Reg#(CommitState) commitState,
    CsrFile csrf,
`ifdef CONFIG_DIFFTEST
    Reg#(DiffArchCsrState) csrSnapReg,
`endif
    Reg#(CommitCsrSnapshot) commitCsrSnapReg,
    PRF prf,
    RAT rat,
    TlbArray tlb,
    Reg#(Addr) pcReg,
    ICache iCache,
    DCache dCache,
    Reg#(Bool) if2WaitRefill,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    ResStation#(16) aluRS,
    ResStation#(4) muldivRS,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    StoreForwardBuf#(16) committedStoreBuf,
    Reg#(Bool) aluBusy,
    Reg#(Bool) mulInFlight,
    Reg#(Bool) divInFlight,
    Reg#(MemExecState) memState,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) accBusy,
    Reg#(Bool) accReqObsolete,
    BranchPredictor branchPred
`ifdef CONFIG_DIFFTEST
    , Difftest difftest
    , Vector#(32, Reg#(Data)) archRegs
`endif
);
  action
    let head = rob.head;
    let result <- doCommitNormalSharedAction(rob, csrf,
`ifdef CONFIG_DIFFTEST
      csrSnapReg,
`endif
      commitCsrSnapReg, prf, rat, tlb, pcReg, iCache, dCache,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, committedStoreBuf, aluBusy,
      mulInFlight, divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred
`ifdef CONFIG_DIFFTEST
      , difftest, archRegs
`endif
    );

    if (result.retired) begin
      if (head.dst matches tagged Valid .dst &&& dst != 0) begin
        rat.updateRet(dst, fromMaybe(?, head.pDst));
      end
`ifdef CONFIG_TRACE_PERFORMANCE
      inst_count();
`endif
    end

    if (result.waitTlb) begin
      commitState <= CommitTLBWait;
    end else begin
      commitState <= CommitIdle;
    end

    if (result.deqRob) begin
      if (head.isBranch) begin
        Bool actualTaken = (head.iType == Br) ? (head.correctTarget != head.pc + 4) : True;
        CfiType cfiType = (head.iType == Br) ? CFI_COND :
                          ((head.iType == J) ? CFI_JAL : CFI_JALR);
        branchPred.commitHistory(actualTaken, head.correctTarget, cfiType);
      end
      rob.deq;
    end
  endaction
endfunction

endpackage
