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
import ConfigReg::*;
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
import FrontendFastPathQueue::*;
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
`ifdef CONFIG_TRACE_PERFORMANCE
import Perf::*;
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
  StoreForwardBuf#(16) committedStoreBuf <- mkStoreForwardBuf;

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

  FastPathQueue         fastQ <- mkFastPathQueue;
  Reg#(Addr)        fastGenPc <- mkReg(startpc);
  Reg#(FrontendEpoch) frontendEpoch <- mkReg(0);

  Reg#(Bool)          accBusy <- mkReg(False);
  Reg#(FastPathQSeq) accReqSeq <- mkReg(0);
  Reg#(FrontendEpoch) accReqEpoch <- mkReg(0);
  Reg#(Addr)         accReqPc <- mkRegU;
  Reg#(Addr) accReqFastPredPc <- mkRegU;
  Reg#(Bool)   accReqObsolete <- mkReg(False);

  Reg#(Bool) fetchInflightValid <- mkReg(False);
  Reg#(FetchInflight) fetchInflight <- mkRegU;

  // Execution state
  Reg#(Bool)         aluBusy <- mkReg(False);
  Reg#(Bool)   aluBranchBusy <- mkReg(False);
  Reg#(RSEntry)   aluExecEntry <- mkRegU;

  Reg#(Bool)     mulInFlight <- mkReg(False);
  Reg#(RSEntry)  mulExecEntry <- mkRegU;

  Reg#(Bool)     divInFlight <- mkReg(False);
  Reg#(RSEntry)  divExecEntry <- mkRegU;

  Reg#(MemExecState) memState <- mkReg(MemIdle);
  Reg#(RSEntry)   memExecEntry <- mkRegU;

  Reg#(Addr)        memVaddr  <- mkRegU;
  Reg#(Addr)        memPaddr  <- mkRegU;
  Reg#(ExcpInfo)    memExcpInfo <- mkRegU;
  Reg#(StoreForwardResult) memForward <- mkReg(StoreForwardResult{data: 0, byteEn: 0});

  // Commit state
  ConfigReg#(CommitState) commitState <- mkConfigReg(CommitIdle);
`ifdef CONFIG_DIFFTEST
  Reg#(DiffArchCsrState) csrSnapReg <- mkRegU;
`endif
  Reg#(CommitCsrSnapshot) commitCsrSnapReg <- mkRegU;

  Reg#(Bool)         idleLock <- mkReg(False);

  // I-Cache miss tracking
  Reg#(Bool)        if2WaitRefill <- mkReg(False);
  Reg#(Addr)         if2MissPaddr  <- mkRegU;

  // Pipeline FIFOs
  Fifo#(2, F1toF2)       f1f2Fifo <- mkCFFifo;
  Fifo#(2, F2D)            f2dFifo <- mkCFFifo;
  Fifo#(2, D2RN)           d2rnFifo <- mkCFFifo;
  Fifo#(2, RenamedInst)   rn2diFifo <- mkCFFifo;

`ifdef CONFIG_TRACE_PERFORMANCE
  rule countFetchStall (!idleLock && if2WaitRefill);
    perf_fetch_stall_cycle();
    perf_icache_miss_cycle();
  endrule

  rule countFrontendWaitFetchCycles (commitState != CommitInterruptReady && fetchInflightValid);
    perf_frontend_wait_fetch_cycles();
  endrule

  rule countFrontendWaitDecodeCycles (commitState != CommitInterruptReady && f2dFifo.notEmpty && !d2rnFifo.notFull);
    perf_frontend_wait_decode_cycles();
  endrule

  rule countFpqDepthAndDepthSamples (commitState != CommitInterruptReady && !idleLock);
    Bit#(64) confirmedDepth = zeroExtend(fastQ.accSeqValue - fastQ.deqSeqValue);
    Bit#(64) unverifiedDepth = zeroExtend(fastQ.enqSeqValue - fastQ.accSeqValue);

    perf_fpq_confirmed_depth(confirmedDepth);
    perf_fpq_unverified_depth(unverifiedDepth);
  endrule

  rule countFpqFullCycles (commitState != CommitInterruptReady && !idleLock && !branchPred.accurateReady && !aluBranchBusy && !fastQ.notFull);
    perf_fpq_full_cycles();
  endrule

  rule countDispatchDependencyStall (rn2diFifo.notEmpty);
    let rInst = rn2diFifo.first;
    if (!prf.isReady(rInst.pSrc1) || !prf.isReady2(rInst.pSrc2)) begin
      perf_dispatch_dependency_stall_cycle();
    end
  endrule

  rule countMemoryStall (memState != MemIdle);
    perf_memory_stall_cycle();
  endrule
`endif

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
  // Frontend fast-path queue, accurate cursor, and fetch engine
  // ============================================================
  rule releaseIdleOnInterrupt (idleLock && csrf.interruptDetected.valid);
    idleLock <= False;
  endrule

  rule doFrontendAccurateComplete (branchPred.accurateReady);
    let accResult <- branchPred.getAccurateResult;
    Bool validReq = accBusy && accReqEpoch == frontendEpoch &&
      !accReqObsolete && accReqSeq == fastQ.accSeqValue;

    if (validReq) begin
      Addr actual = refinedNextPc(accResult, accReqPc);
      Bool mismatch = actual != accReqFastPredPc;
      if (mismatch) begin
        `ifdef CONFIG_TRACE_PERFORMANCE
            perf_accurate_override();
        `endif
        `ifdef CONFIG_TRACE_PERFORMANCE
            perf_accurate_truncated_entries();
        `endif
        fastQ.truncateAfterAcc(actual);
        fastGenPc <= actual;
      end else begin
        `ifdef CONFIG_TRACE_PERFORMANCE
            perf_accurate_match();
        `endif
        fastQ.confirmAcc(actual);
      end
    end else begin
      if (accReqObsolete) begin
        `ifdef CONFIG_TRACE_PERFORMANCE
            perf_accurate_obsolete_drop();
        `endif
      end else if (accReqEpoch != frontendEpoch || accReqSeq != fastQ.accSeqValue) begin
        `ifdef CONFIG_TRACE_PERFORMANCE
            perf_accurate_stale_drop();
        `endif
      end
    end

    accBusy <= False;
    accReqObsolete <= False;
  endrule

  rule doFrontendFetchRefill (commitState != CommitInterruptReady && !aluBranchBusy &&
      !branchPred.accurateReady && fetchInflightValid && if2WaitRefill && f2dFifo.notFull);
    doFetchRefillRespBody(fetchInflight, fetchInflightValid, if2MissPaddr,
      if2WaitRefill, f2dFifo, iCache, fastQ, fastGenPc, frontendEpoch,
      accBusy, accReqObsolete, branchPred);
  endrule

  rule doFrontendFetchCollectNoFetchTlb (commitState != CommitInterruptReady && !aluBranchBusy &&
      !branchPred.accurateReady && fetchInflightValid && !if2WaitRefill && f2dFifo.notFull &&
      fetchInflight.entry.transType != Translate);
    doFetchProbeRespBody(noTlbLookup, fetchInflight, fetchInflightValid,
      if2MissPaddr, if2WaitRefill, f2dFifo, iCache, fastQ, fastGenPc, frontendEpoch,
      accBusy, accReqObsolete, branchPred);
  endrule

  rule doFrontendFetchCollectWithFetchTlb (commitState != CommitInterruptReady && !aluBranchBusy &&
      !branchPred.accurateReady && fetchInflightValid && !if2WaitRefill && f2dFifo.notFull &&
      fetchInflight.entry.transType == Translate);
    let tlbRes <- tlb.fetchLookupResp;
    doFetchProbeRespBody(tlbRes, fetchInflight, fetchInflightValid,
      if2MissPaddr, if2WaitRefill, f2dFifo, iCache, fastQ, fastGenPc, frontendEpoch,
      accBusy, accReqObsolete, branchPred);
  endrule

  rule doFrontendFetchLaunch (commitState != CommitInterruptReady && !idleLock && !aluBranchBusy &&
      !branchPred.accurateReady && !fetchInflightValid && fastQ.notEmpty);
    let entry = fastQ.first;
    Bool useAccurate = fastQ.fetchUseAccurate;
    Addr nextPc = useAccurate ? entry.selectedPredPc : entry.fastPredPc;
    Bool fastFallback = !useAccurate;
    if (useAccurate) begin
      `ifdef CONFIG_TRACE_PERFORMANCE
          perf_fetch_use_accurate();
      `endif
    end else begin
      `ifdef CONFIG_TRACE_PERFORMANCE
          perf_fetch_fast_fallback();
      `endif
    end

    FastPathQSeq deqSeq = fastQ.deqSeqValue;

    iCache.probe(entry.pc);
    if (entry.transType == Translate) begin
      tlb.fetchLookupReq(entry.pc, entry.asid);
    end

    fetchInflight <= FetchInflight{entry: entry, nextPc: nextPc};
    fetchInflightValid <= True;
    fastQ.deqFetch(fastFallback);

    `ifdef CONFIG_TRACE_PERFORMANCE

        perf_fpq_deq_fetch();

    `endif

    if (fastFallback && accBusy && accReqSeq == deqSeq && accReqEpoch == entry.epoch) begin
      accReqObsolete <= True;
    end
  endrule

  rule doFrontendAccurateStart (commitState != CommitInterruptReady && !idleLock &&
      !branchPred.accurateReady && !accBusy && fetchInflightValid && fastQ.hasUnverified);
    let entry = fastQ.accFirst;
    `ifdef CONFIG_TRACE_PERFORMANCE
        perf_accurate_started();
    `endif
    branchPred.startAccurate(entry.pc);
    accBusy <= True;
    accReqSeq <= fastQ.accSeqValue;
    accReqEpoch <= entry.epoch;
    accReqPc <= entry.pc;
    accReqFastPredPc <= entry.fastPredPc;
    accReqObsolete <= False;
  endrule

  rule doFrontendFastEnq (commitState != CommitInterruptReady && !idleLock &&
      !branchPred.accurateReady && fastQ.notFull);
    Addr pc = fastGenPc;
    Addr fastPredPc = branchPred.predict(pc);
    MmuTranslateType transType = getMmuTranslateType(csrf.crmd);
    `ifdef CONFIG_TRACE_PERFORMANCE
        perf_fpq_enq_fast();
    `endif

    fastQ.enqFast(FastPathQEntry{
      pc: pc,
      fastPredPc: fastPredPc,
      selectedPredPc: fastPredPc,
      crmd: csrf.crmd,
      asid: csrf.asid,
      dmw0: csrf.dmw0,
      dmw1: csrf.dmw1,
      transType: transType,
      epoch: frontendEpoch
    });
    fastGenPc <= fastPredPc;
  endrule

  // ============================================================
  // ID Stage (modified: d2rFifo -> d2rnFifo)
  // ============================================================
  rule doDecode (commitState != CommitInterruptReady);
    doDecodeBody(f2dFifo, d2rnFifo);
  endrule

  // ============================================================
  // RN Stage: Rename - RAT lookup, FreeList alloc, ROB enq
  // ============================================================
  rule doRename (commitState != CommitInterruptReady && !aluBranchBusy && !idleLock &&
      d2rnFifo.notEmpty && rn2diFifo.notFull && rob.notFull &&
      (!renameNeedsFree(d2rnFifo.first) || freeList.notEmpty));
    doRenameBody(d2rnFifo, rn2diFifo, rat, freeList, prf, rob);
  endrule

  // ============================================================
  // DI Stage: Dispatch to RS based on instruction type
  // ============================================================
  rule doDispatchAlu (commitState != CommitInterruptReady && rn2diFifo.notEmpty && aluRS.notFull && dispIsAlu(rn2diFifo.first));
    doDispatchAluBody(rn2diFifo, prf, aluRS);
  endrule

  rule doDispatchMulDiv (commitState != CommitInterruptReady && rn2diFifo.notEmpty && muldivRS.notFull && dispIsMul(rn2diFifo.first));
    doDispatchMulDivBody(rn2diFifo, prf, muldivRS);
  endrule

  rule doDispatchMem (commitState != CommitInterruptReady && rn2diFifo.notEmpty && memRS.notFull && dispIsMem(rn2diFifo.first));
    doDispatchMemBody(rn2diFifo, prf, memRS);
  endrule

  rule doDispatchSpecial (commitState != CommitInterruptReady && rn2diFifo.notEmpty && dispIsSpecial(rn2diFifo.first));
    doDispatchSpecialBody(rn2diFifo);
  endrule

  // ============================================================
  // CDB: Wakeup RS entries and writeback to PRF
  // ============================================================
  rule wakeupAluRS (commitState != CommitInterruptReady && cdb.anyValid);
    aluRS.wakeup(cdb.msgs);
  endrule

  rule wakeupMuldivRS (commitState != CommitInterruptReady && cdb.anyValid);
    muldivRS.wakeup(cdb.msgs);
  endrule

  rule wakeupMemRS (commitState != CommitInterruptReady && cdb.anyValid);
    memRS.wakeup(cdb.msgs);
  endrule

  rule writebackLoad (commitState != CommitInterruptReady && cdb.msgs[0].valid);
    let m = cdb.msgs[0];
    prf.cdbWriteLoad(m.tag, m.value);
    prf.setReadyLoad(m.tag);
  endrule

  rule writebackALU (commitState != CommitInterruptReady && cdb.msgs[1].valid);
    let m = cdb.msgs[1];
    prf.cdbWriteALU(m.tag, m.value);
    prf.setReadyALU(m.tag);
  endrule

  rule writebackMul (commitState != CommitInterruptReady && cdb.msgs[2].valid);
    let m = cdb.msgs[2];
    prf.cdbWriteMul(m.tag, m.value);
    prf.setReadyMul(m.tag);
  endrule

  rule writebackDiv (commitState != CommitInterruptReady && cdb.msgs[3].valid);
    let m = cdb.msgs[3];
    prf.cdbWriteDiv(m.tag, m.value);
    prf.setReadyDiv(m.tag);
  endrule

  // ============================================================
  // IS/EX Stage: ALU issue and execute
  // ============================================================
  rule doIssueALU (commitState == CommitIdle && !aluBusy && !isCsrTlbSpecial(rob.headIType) &&
      !coreIsBarrier(rob.headIType) &&&
      aluRS.selectOldestReadyForAlu(rob.headTag, rob.headValid) matches tagged Valid .entry);
    doIssueALUBody(entry, aluExecEntry, aluRS, aluBusy);
    aluBranchBusy <= isBranch(entry.iType);
  endrule

  rule doExecALUBranch (commitState != CommitInterruptReady && aluBusy && aluBranchBusy);
    doExecALUBody(aluExecEntry, aluBusy, cdb, rob, pcReg[1], iCache, tlb,
      f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo, aluRS, muldivRS, memRS,
      storeBuf, if2WaitRefill, rat, freeList, branchPred,
      fastQ, fastGenPc, frontendEpoch, fetchInflightValid, accBusy, accReqObsolete);
    aluBranchBusy <= False;
  endrule

  rule doExecALUNonBranch (commitState != CommitInterruptReady && aluBusy && !aluBranchBusy);
    doExecALUBody(aluExecEntry, aluBusy, cdb, rob, pcReg[1], iCache, tlb,
      f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo, aluRS, muldivRS, memRS,
      storeBuf, if2WaitRefill, rat, freeList, branchPred,
      fastQ, fastGenPc, frontendEpoch, fetchInflightValid, accBusy, accReqObsolete);
    aluBranchBusy <= False;
  endrule

  // ============================================================
  // IS/EX Stage: MulDiv issue and collect
  // ============================================================

  rule doIssueMul (commitState == CommitIdle && !mulInFlight && !isCsrTlbSpecial(rob.headIType) &&
      !coreIsBarrier(rob.headIType) &&&
      muldivRS.selectOldestReady matches tagged Valid .entry &&&
      isMulFunc(fromMaybe(?, entry.muldivFunc)));
    doIssueMulBody(entry, mulUnit, mulExecEntry, muldivRS, mulInFlight);
  endrule

  rule doIssueDiv (commitState == CommitIdle && !divInFlight && !isCsrTlbSpecial(rob.headIType) &&
      !coreIsBarrier(rob.headIType) &&&
      muldivRS.selectOldestReady matches tagged Valid .entry &&&
      isDivFunc(fromMaybe(?, entry.muldivFunc)));
    doIssueDivBody(entry, divUnit, divExecEntry, muldivRS, divInFlight);
  endrule

  rule doCollectMul (commitState != CommitInterruptReady && !aluBranchBusy && mulInFlight && mulUnit.finish);
    doCollectMulBody(mulInFlight, mulExecEntry, mulUnit, cdb, rob);
  endrule

  rule doCollectDiv (commitState != CommitInterruptReady && !aluBranchBusy && divInFlight && divUnit.finish);
    doCollectDivBody(divInFlight, divExecEntry, divUnit, cdb, rob);
  endrule

  // ============================================================
  // IS/EX Stage: Memory issue and collect
  // ============================================================
  Reg#(Bool) memNeedTlb <- mkReg(False);

  rule doIssueMem (commitState == CommitIdle && memState == MemIdle && !storeBuf.hasPendingDrain &&
      !(rob.headValid && rob.head.iType == St && rob.head.state == RobCompleted) &&
      !isCsrTlbSpecial(rob.headIType) &&&
      memRS.selectOldestReadyFrom(rob.headTag) matches tagged Valid .entry &&&
      // Only ordinary loads may execute away from the ROB head.  Stores,
      // LL/SC, barriers and cache maintenance have architectural side
      // effects and are serialized.  A translated MMIO load is delayed
      // again below until it reaches the head.
      (entry.iType == Ld || entry.robTag == rob.headTag) &&
      (entry.iType != St || storeBuf.notFull) &&
      (!entry.isLoad || !memRS.hasOlderStore(entry.robTag, rob.headTag)));
    doIssueMemBody(entry, memExecEntry, memVaddr, memPaddr, memExcpInfo,
      memNeedTlb, memState, csrf, tlb, iCache, rob, memRS, storeBuf);
  endrule

  rule doReportMemExcp (commitState != CommitInterruptReady && !aluBranchBusy && memState == MemExcpWait);
    doReportMemExcpBody(memState, memExecEntry, memExcpInfo, rob, memRS);
  endrule

  rule doCollectMemTLB (commitState != CommitInterruptReady && !aluBranchBusy && memState == MemTLBWait && memNeedTlb);
    doCollectMemTLBBody(memState, memExecEntry, memVaddr,
      memPaddr, memForward, csrf, tlb, iCache, dCache, rob, memRS, storeBuf);
  endrule

  rule doCollectMemDirect (commitState != CommitInterruptReady && !aluBranchBusy && memState == MemTLBWait && !memNeedTlb);
    doCollectMemDirectBody(memState, memExecEntry, memVaddr, memPaddr,
      memForward, csrf, iCache, dCache, rob, memRS, storeBuf);
  endrule

  rule cancelDeadMemUncache (commitState != CommitInterruptReady && memState == MemUncacheWait &&
      !rob.tokenAlive(memExecEntry.token));
    memState <= MemIdle;
  endrule

  rule doIssueMemUncache (commitState != CommitInterruptReady && memState == MemUncacheWait &&
      rob.tokenAlive(memExecEntry.token) && memExecEntry.robTag == rob.headTag && !storeBuf.hasPendingDrain);
    doIssueMemUncacheBody(memState, memExecEntry, memVaddr, memPaddr,
      memForward, dCache, storeBuf, rob.headTag);
  endrule

  rule doCollectMemCache (commitState != CommitInterruptReady && !aluBranchBusy && memState == MemCacheWait &&
      !storeBuf.firstIssuedUncache);
    doCollectMemCacheBody(memState, memExecEntry, memVaddr, memPaddr,
      memForward, dCache, cdb, rob, memRS);
  endrule

  rule doCollectMemCacopI (commitState != CommitInterruptReady && !aluBranchBusy && memState == MemCacopIWait);
    doCollectMemCacopIBody(memState, memExecEntry, iCache, rob, memRS);
  endrule

  rule doCollectMemIbar (commitState != CommitInterruptReady && !aluBranchBusy && memState == MemIbarWait);
    doCollectMemIbarBody(memState, memExecEntry, iCache, rob, memRS);
  endrule

  rule drainCommittedStore (commitState != CommitInterruptReady && memState == MemIdle &&
      storeBuf.notEmpty && storeBuf.first.state == StoreCommitted);
    let e = storeBuf.first;
    dCache.req(MemReq{
      op: St, addr: e.vaddr, paddr: e.paddr, useCache: e.useCache,
      data: e.data, byteEn: truncate(e.byteEn),
      size: memByteEnToAxiSize(truncate(e.byteEn)), cacheOp: 5'b0
    });
    if (e.useCache) begin
      storeBuf.deq;
    end else begin
      storeBuf.markIssued(e.owner);
    end
  endrule

  rule completeIssuedUncacheStore (commitState == CommitIdle &&
      storeBuf.notEmpty && storeBuf.first.state == StoreIssued && !storeBuf.first.useCache);
    let done <- dCache.resp;
    storeBuf.complete(storeBuf.first.owner);
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
    takeCsrSnapshotBody(
`ifdef CONFIG_DIFFTEST
      csrSnapReg,
`endif
      commitCsrSnapReg, csrf, rob, commitState);
  endrule

  rule doCommitInterrupt (rob.headValid && commitState == CommitInterruptReady
`ifdef CONFIG_DIFFTEST
      && difftest.enqTraceReady
`endif
  );
    doCommitTrapAction(CommitTrapInfo{
        ecode: `ECODE_INT,
        esubcode: `ESUBCODE_NONE,
        badv: 0,
        isInterrupt: True,
        interruptNo: commitCsrSnapReg.interruptInfo.interruptNo
      },
      rob, commitState, csrf,
`ifdef CONFIG_DIFFTEST
      csrSnapReg,
`endif
      rat, freeList, tlb, pcReg[2], iCache, dCache,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, aluBusy, mulInFlight,
      divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred
`ifdef CONFIG_DIFFTEST
      , difftest, archRegs
`endif
    );
  endrule

  rule doCommitErtn (rob.headValid && commitState == CommitReady
`ifdef CONFIG_DIFFTEST
      && difftest.enqTraceReady
`endif
      && rob.head.iType == Ertn);
    doCommitBody(rob
`ifdef CONFIG_WB_DEBUG
      , debugWsValidWire, debugWbPcWire
`ifdef CONFIG_WB_DEBUG_INST
      , debugWbInstWire
`endif
`endif
    );
    doCommitErtnAction(rob, commitState, csrf,
`ifdef CONFIG_DIFFTEST
      csrSnapReg,
`endif
      commitCsrSnapReg, rat, freeList, tlb, pcReg[2], iCache, dCache,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, aluBusy, mulInFlight,
      divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred
`ifdef CONFIG_DIFFTEST
      , difftest, archRegs
`endif
    );
  endrule

  rule doCommitRedirect (rob.headValid && commitState == CommitReady
`ifdef CONFIG_DIFFTEST
      && difftest.enqTraceReady
`endif
      && (rob.head.excp.valid || rob.head.iType == Idle ||
       rob.head.iType == Syscall || rob.head.iType == Break));
    doCommitBody(rob
`ifdef CONFIG_WB_DEBUG
      , debugWsValidWire, debugWbPcWire
`ifdef CONFIG_WB_DEBUG_INST
      , debugWbInstWire
`endif
`endif
    );
    doCommitRedirectAction(rob, commitState, csrf,
`ifdef CONFIG_DIFFTEST
      csrSnapReg,
`endif
      rat, freeList, tlb, pcReg[2], iCache, dCache,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, idleLock, aluBusy, mulInFlight,
      divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred
`ifdef CONFIG_BSIM
      , prf
      , toHostFifo
`endif
`ifdef CONFIG_DIFFTEST
      , difftest, archRegs
`endif
    );
  endrule

  rule doCommitIbar (rob.headValid && commitState == CommitReady
`ifdef CONFIG_DIFFTEST
      && difftest.enqTraceReady
`endif
      && !(rob.head.excp.valid || rob.head.iType == Ertn || rob.head.iType == Idle ||
       rob.head.iType == Syscall || rob.head.iType == Break)
      && rob.head.iType == Ibar);
    doCommitBody(rob
`ifdef CONFIG_WB_DEBUG
      , debugWsValidWire, debugWbPcWire
`ifdef CONFIG_WB_DEBUG_INST
      , debugWbInstWire
`endif
`endif
    );
    doCommitIbarAction(rob, commitState,
`ifdef CONFIG_DIFFTEST
      csrSnapReg,
`endif
      rat, freeList, tlb, pcReg[2], iCache,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, aluBusy, mulInFlight,
      divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred
`ifdef CONFIG_DIFFTEST
      , difftest, archRegs
`endif
    );
  endrule

  rule doCommitReclaim (rob.headValid && commitState == CommitReady
`ifdef CONFIG_DIFFTEST
      && difftest.enqTraceReady
`endif
      && !(rob.head.excp.valid || rob.head.iType == Ertn || rob.head.iType == Idle ||
       rob.head.iType == Syscall || rob.head.iType == Break)
      && isValid(rob.head.oldPdst)
      && rob.head.iType != Ibar);
    doCommitBody(rob
`ifdef CONFIG_WB_DEBUG
      , debugWsValidWire, debugWbPcWire
`ifdef CONFIG_WB_DEBUG_INST
      , debugWbInstWire
`endif
`endif
    );
    doCommitReclaimAction(rob, commitState, csrf,
`ifdef CONFIG_DIFFTEST
      csrSnapReg,
`endif
      commitCsrSnapReg, prf, rat, freeList, tlb, pcReg[2], iCache, dCache,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, committedStoreBuf, aluBusy, mulInFlight,
      divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred
`ifdef CONFIG_DIFFTEST
      , difftest, archRegs
`endif
    );
  endrule

  rule doCommitNoReclaim (rob.headValid && commitState == CommitReady
`ifdef CONFIG_DIFFTEST
      && difftest.enqTraceReady
`endif
      && !(rob.head.excp.valid || rob.head.iType == Ertn || rob.head.iType == Idle ||
       rob.head.iType == Syscall || rob.head.iType == Break)
      && !isValid(rob.head.oldPdst)
      && rob.head.iType != Ibar);
    doCommitBody(rob
`ifdef CONFIG_WB_DEBUG
      , debugWsValidWire, debugWbPcWire
`ifdef CONFIG_WB_DEBUG_INST
      , debugWbInstWire
`endif
`endif
    );
    doCommitNoReclaimAction(rob, commitState, csrf,
`ifdef CONFIG_DIFFTEST
      csrSnapReg,
`endif
      commitCsrSnapReg, prf, rat, tlb, pcReg[2], iCache, dCache,
      if2WaitRefill, f1f2Fifo, f2dFifo, d2rnFifo, rn2diFifo,
      aluRS, muldivRS, memRS, storeBuf, committedStoreBuf, aluBusy, mulInFlight,
      divInFlight, memState, fastQ, fastGenPc, frontendEpoch,
      fetchInflightValid, accBusy, accReqObsolete, branchPred
`ifdef CONFIG_DIFFTEST
      , difftest, archRegs
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

`ifdef CONFIG_DIFFTEST
  method Data rfRdata = debugInforFlag ? archRegs[debugRegNum] : 0;
`else
  method Data rfRdata = debugInforFlag ? prf.rdDbg(rat.lookupRet(debugRegNum)) : 0;
`endif

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
