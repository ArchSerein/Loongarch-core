import Types::*;
import ProcTypes::*;
import MemTypes::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import Mmu::*;
import Tlb::*;
import Fifo::*;
import Ehr::*;
import Vector::*;
import ICache::*;
import DCache::*;
import Mul::*;
import Div::*;
import AxiTypes::*;
import AxiMem::*;
import CoreTypes::*;
import CoreFunc::*;
import BranchPredictor::*;
import BranchPredTypes::*;
import OoOTypes::*;
import PRF::*;
import RAT::*;
import FreeList::*;
import ROB::*;
import ResStation::*;
import CDB::*;
import StoreBuf::*;

import Ifetch::*;
import Idecode::*;
import Rename::*;
import Dispatch::*;
import Issue::*;
import Collect::*;
import Commit::*;

`include "Autoconf.bsv"
`ifdef CONFIG_VSIM
`define CONFIG_WB_DEBUG
`define CONFIG_WB_DEBUG_INST
`endif
`ifdef CONFIG_FPGA
`define CONFIG_WB_DEBUG
`endif
`include "CsrAddr.bsv"
`ifdef CONFIG_DIFFTEST
import DiffTypes::*;
import Difftest::*;
`endif

(* synthesize *)
module mkCore(Core);
  // PC register: port[0]=IF1, port[1]=EX mispredict, port[2]=CM exception/ertn
  Ehr#(3, Addr)         pcReg <- mkEhr(startpc);
  CsrFile                csrf <- mkCsrFile;

  // OoO structures
  PRF                     prf <- mkPRF;
  RAT                     rat <- mkRAT;
  FreeList           freeList <- mkFreeList;
  ROB                     rob <- mkROB;
  CDB                     cdb <- mkCDB;
  ResStation#(16)      aluRS <- mkResStation;
  ResStation#(4)   muldivRS <- mkResStation;
  ResStation#(16)      memRS <- mkResStation;
  StoreBuf#(16)     storeBuf <- mkStoreBuf;

`ifdef CONFIG_DIFFTEST
  // Shadow ARF for Difftest and debug
  Vector#(32, Reg#(Data)) archRegs <- replicateM(mkReg(0));
  Difftest           difftest <- mkDifftest;
`endif

  // Caches, TLB, functional units
  ICache               iCache <- mkICache;
  DCache               dCache <- mkDCache;
  Mul_ifc             mulUnit <- mkMul;
  Div_ifc             divUnit <- mkDiv;
  AxiMemMaster        axiMux <- mkAxiArbiter2(iCache.axiMem, dCache.axiMem);
  BranchPredictor  branchPred <- mkBranchPredictor;
  TlbArray                tlb <- mkTlb;

  // Execution state
  Reg#(Bool)         aluBusy <- mkReg(False);
  Reg#(RSEntry)   aluExecEntry <- mkRegU;

  Reg#(Bool)     mulInFlight <- mkReg(False);
  Reg#(RSEntry)  mulExecEntry <- mkRegU;

  Reg#(Bool)     divInFlight <- mkReg(False);
  Reg#(RSEntry)  divExecEntry <- mkRegU;

  Reg#(MemExecState) memState <- mkReg(MemIdle);
  Reg#(RSEntry)   memExecEntry <- mkRegU;
  Reg#(Addr)        memVaddr  <- mkRegU;
  Reg#(Addr)        memPaddr  <- mkRegU;

  // Commit state
  Reg#(CommitState) commitState <- mkReg(CommitIdle);
  Reg#(DiffArchCsrState) csrSnapReg <- mkRegU;
  Reg#(Bit#(64)) stableCounterReg <- mkReg(0);

  Reg#(Bool)         idleLock <- mkReg(False);

  // I-Cache miss tracking
  Reg#(Bool)        if2WaitRefill <- mkReg(False);
  Reg#(F1toF2)       if2PendingReq <- mkRegU;
  Reg#(Addr)         if2MissPaddr  <- mkRegU;

  // Pipeline FIFOs
  Fifo#(2, F1toF2)       f1f2Fifo <- mkCFFifo;
  Fifo#(2, F2D)            f2dFifo <- mkCFFifo;
  Fifo#(2, D2RN)           d2rnFifo <- mkCFFifo;
  Fifo#(2, RenamedInst)   rn2diFifo <- mkCFFifo;

`ifdef CONFIG_BSIM
  Fifo#(2, CpuToHostData) toHostFifo <- mkCFFifo;
`endif

`ifdef CONFIG_WB_DEBUG
  Wire#(Bool)       debugBreakPoint <- mkDWire(False);
  Wire#(Bool)       debugInforFlag <- mkDWire(False);
  Wire#(RIndx)      debugRegNum <- mkDWire(0);
  Wire#(Bool)       debugWsValidWire <- mkDWire(False);
  Wire#(Addr)       debugWbPcWire <- mkDWire(0);
  Wire#(Bit#(4))    debugWbRfWenWire <- mkDWire(0);
  Wire#(RIndx)      debugWbRfWnumWire <- mkDWire(0);
  Wire#(Data)       debugWbRfWdataWire <- mkDWire(0);
`ifdef CONFIG_WB_DEBUG_INST
  Wire#(Instruction) debugWbInstWire <- mkDWire(0);
`endif
`endif

  // ============================================================
  // IF1 Stage (unchanged)
  // ============================================================
  rule releaseIdleOnInterrupt (idleLock && csrf.interruptDetected);
    idleLock <= False;
  endrule

  rule doIF1NoFetchTlb (!idleLock && !if2WaitRefill && !f1f2Fifo.notEmpty &&
      getMmuTranslateType(csrf.crmd) != Translate);
    doIF1Body(pcReg[0], csrf.crmd, csrf.asid, csrf.dmw0, csrf.dmw1, getMmuTranslateType(csrf.crmd),
              branchPred, iCache, f1f2Fifo, pcReg[0]);
  endrule

  rule doIF1WithFetchTlb (!idleLock && !if2WaitRefill && !f1f2Fifo.notEmpty &&
      getMmuTranslateType(csrf.crmd) == Translate);
    Addr pc = pcReg[0];
    Data asid = csrf.asid;
    tlb.fetchLookupReq(pc, asid);
    doIF1Body(pc, csrf.crmd, asid, csrf.dmw0, csrf.dmw1, Translate,
              branchPred, iCache, f1f2Fifo, pcReg[0]);
  endrule

  // ============================================================
  // IF2 Stage (unchanged)
  // ============================================================
  rule doIF2if2WaitRefill (if2WaitRefill);
    let req = if2PendingReq;
    let iResp <- iCache.refillResp;
    if (iResp.addr == if2MissPaddr) begin
      f2dFifo.enq(F2D{
        pc: req.pc,
        predPc: req.predPc,
        inst: iResp.inst,
        instPaddr: if2MissPaddr,
        excp: mkNoExcp
      });
      if2WaitRefill <= False;
      pcReg[0] <= req.predPc;
    end
  endrule

  rule doIF2NoFetchTlb (!if2WaitRefill &&
      f1f2Fifo.first.transType != Translate);
    doIF2Body(noTlbLookup, f1f2Fifo, f2dFifo, iCache, if2PendingReq, if2MissPaddr, if2WaitRefill);
  endrule

  rule doIF2WithFetchTlb (!if2WaitRefill &&
      f1f2Fifo.first.transType == Translate);
    let tlbRes <- tlb.fetchLookupResp;
    doIF2Body(tlbRes, f1f2Fifo, f2dFifo, iCache, if2PendingReq, if2MissPaddr, if2WaitRefill);
  endrule

  // ============================================================
  // ID Stage (modified: d2rFifo -> d2rnFifo)
  // ============================================================
  rule doDecode;
    doDecodeBody(f2dFifo, d2rnFifo);
  endrule

  // ============================================================
  // RN Stage: Rename - RAT lookup, FreeList alloc, ROB enq
  // ============================================================
  rule doRename (!idleLock &&
      d2rnFifo.notEmpty && rn2diFifo.notFull && rob.notFull &&
      (!renameNeedsFree(d2rnFifo.first) || freeList.notEmpty));
    doRenameBody(d2rnFifo, rn2diFifo, rat, freeList, prf, rob);
  endrule

  // ============================================================
  // DI Stage: Dispatch to RS based on instruction type
  // ============================================================
  rule doDispatchAlu (rn2diFifo.notEmpty && dispIsAlu(rn2diFifo.first));
    doDispatchAluBody(rn2diFifo, prf, aluRS);
  endrule

  rule doDispatchMulDiv (rn2diFifo.notEmpty && dispIsMul(rn2diFifo.first));
    doDispatchMulDivBody(rn2diFifo, prf, muldivRS);
  endrule

  rule doDispatchMem (rn2diFifo.notEmpty && dispIsMem(rn2diFifo.first));
    doDispatchMemBody(rn2diFifo, prf, memRS);
  endrule

  rule doDispatchSpecial (rn2diFifo.notEmpty && dispIsSpecial(rn2diFifo.first));
    doDispatchSpecialBody(rn2diFifo);
  endrule

  // ============================================================
  // CDB: Wakeup RS entries and writeback to PRF
  // ============================================================
  rule wakeupOnCDB (cdb.valid);
    let msg = cdb.msg;
    aluRS.wakeup(msg);
    muldivRS.wakeup(msg);
    memRS.wakeup(msg);
  endrule

  rule writebackToPRF (cdb.valid);
    let msg = cdb.msg;
    prf.cdbWrite(msg.tag, msg.value);
    prf.setReady(msg.tag);
  endrule

  // ============================================================
  // IS/EX Stage: ALU issue and execute
  // ============================================================
  rule doIssueALU (!aluBusy && !isCsrTlbSpecial(rob.headIType) &&&
      aluRS.selectOldestReady matches tagged Valid .entry &&&
      (!isBranch(entry.iType) || (rob.headValid && rob.headTag == entry.robTag)));
    doIssueALUBody(entry, aluExecEntry, aluRS, aluBusy);
  endrule

  rule doExecALU (aluBusy);
    doExecALUBody(aluExecEntry, aluBusy, cdb, rob, pcReg[1], iCache, tlb,
      f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo, aluRS, muldivRS, memRS,
      if2WaitRefill, rat, freeList, branchPred);
  endrule

  // ============================================================
  // IS/EX Stage: MulDiv issue and collect
  // ============================================================

  rule doIssueMul (!mulInFlight && !isCsrTlbSpecial(rob.headIType) &&&
      muldivRS.selectOldestReady matches tagged Valid .entry &&&
      isMulFunc(fromMaybe(?, entry.muldivFunc)));
    doIssueMulBody(entry, mulUnit, mulExecEntry, muldivRS, mulInFlight);
  endrule

  rule doIssueDiv (!divInFlight && !isCsrTlbSpecial(rob.headIType) &&&
      muldivRS.selectOldestReady matches tagged Valid .entry &&&
      isDivFunc(fromMaybe(?, entry.muldivFunc)));
    doIssueDivBody(entry, divUnit, divExecEntry, muldivRS, divInFlight);
  endrule

  rule doCollectMul (mulInFlight && mulUnit.finish);
    doCollectMulBody(mulInFlight, mulExecEntry, mulUnit, cdb, rob);
  endrule

  rule doCollectDiv (divInFlight && divUnit.finish);
    doCollectDivBody(divInFlight, divExecEntry, divUnit, cdb, rob);
  endrule

  // ============================================================
  // IS/EX Stage: Memory issue and collect
  // ============================================================
  Reg#(Bool) memNeedTlb <- mkReg(False);

  rule doIssueMem (memState == MemIdle && !isCsrTlbSpecial(rob.headIType) &&&
      memRS.selectOldestReady matches tagged Valid .entry);
    doIssueMemBody(entry, memExecEntry, memVaddr, memPaddr, memNeedTlb,
      memState, csrf, tlb, iCache, rob, memRS, storeBuf);
  endrule

  rule doCollectMemTLB (memState == MemTLBWait && memNeedTlb);
    doCollectMemTLBBody(memState, memNeedTlb, memExecEntry, memVaddr,
      memPaddr, csrf, tlb, iCache, dCache, rob, memRS);
  endrule

  rule doCollectMemDirect (memState == MemTLBWait && !memNeedTlb);
    doCollectMemDirectBody(memState, memExecEntry, memVaddr, memPaddr,
      iCache, dCache, rob);
  endrule

  rule doCollectMemCache (memState == MemCacheWait);
    doCollectMemCacheBody(memState, memExecEntry, memVaddr, dCache, cdb,
      rob, memRS);
  endrule

  rule doCollectMemCacopI (memState == MemCacopIWait);
    doCollectMemCacopIBody(memState, memExecEntry, iCache, rob, memRS);
  endrule

  // ============================================================
  // CM Stage: Commit
  // ============================================================
  rule doCollectCommitTLB (commitState == CommitTLBWait);
    doCollectCommitTLBBody(commitState, tlb, rob, csrf
`ifdef CONFIG_DIFFTEST
      , csrSnapReg, archRegs, difftest
`endif
`ifdef CONFIG_WB_DEBUG
      , debugWsValidWire, debugWbPcWire
`endif
    );
  endrule


  rule takeCsrSnapshot (rob.headValid && commitState == CommitIdle &&
      (rob.head.state == RobCompleted || rob.head.excp.valid ||
       isCsrTlbSpecial(rob.head.iType)));
    takeCsrSnapshotBody(csrSnapReg, stableCounterReg, csrf, commitState);
  endrule

  rule doCommit (rob.headValid && commitState == CommitReady);
    doCommitBody(rob, commitState, csrf, csrSnapReg, stableCounterReg,
      prf, rat, freeList, tlb, pcReg[2], iCache, dCache,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, idleLock, aluBusy, mulInFlight,
      divInFlight, memState
`ifdef CONFIG_BSIM
      , toHostFifo
`endif
`ifdef CONFIG_DIFFTEST
      , difftest, archRegs
`endif
`ifdef CONFIG_WB_DEBUG
      , debugWsValidWire, debugWbPcWire
`ifdef CONFIG_WB_DEBUG_INST
      , debugWbInstWire
`endif
`endif
    );
  endrule

  // ============================================================
  // Interface methods
  // ============================================================
  method Action setInterrupt(Bit#(8) val);
    csrf.setInterrupt(val);
  endmethod

`ifdef CONFIG_BSIM
  method ActionValue#(CpuToHostData) cpuToHost if (toHostFifo.notEmpty);
    let ret = toHostFifo.first;
    toHostFifo.deq;
    return ret;
  endmethod
  method Bool cpuToHostValid = toHostFifo.notEmpty;
  method Action hostToCpu(Addr startpc);
    noAction;
  endmethod
`endif

`ifdef CONFIG_DIFFTEST
  `ifdef CONFIG_BSIM
  method ActionValue#(DiffTrace) diffTrace;
    let ret <- difftest.diffTrace;
    return ret;
  endmethod
  method Bool diffTraceValid = difftest.diffTraceValid;
  `else
  method Bool diffStepValid = difftest.diffStepValid;
  method Bit#(142) liveDiffCommitBundle = difftest.liveDiffCommitBundle;
  method Bit#(1024) liveDiffRegsBundle = difftest.liveDiffRegsBundle;
  method Bit#(832) liveDiffCsrBundle = difftest.liveDiffCsrBundle;
  method Bit#(130) liveDiffExcpBundle = difftest.liveDiffExcpBundle;
  method Bit#(200) liveDiffStoreBundle = difftest.liveDiffStoreBundle;
  method Bit#(136) liveDiffLoadBundle = difftest.liveDiffLoadBundle;
  `endif
`endif

`ifdef CONFIG_WB_DEBUG
  method Action debugInput(Bool breakPoint, Bool inforFlag, RIndx regNum);
    debugBreakPoint <= breakPoint;
    debugInforFlag <= inforFlag;
    debugRegNum <= regNum;
  endmethod

  method Bool wsValid = debugWsValidWire;

  method Data rfRdata = debugInforFlag ? archRegs[debugRegNum] : 0;

  method Addr debug0WbPc = debugWbPcWire;

  method Bit#(4) debug0WbRfWen = debugWbRfWenWire;

  method RIndx debug0WbRfWnum = debugWbRfWnumWire;

  method Data debug0WbRfWdata = debugWbRfWdataWire;

`ifdef CONFIG_WB_DEBUG_INST
  method Instruction debug0WbInst = debugWbInstWire;
`endif
`endif

  interface axiMem = axiMux;
endmodule
