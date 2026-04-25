import Types::*;
import ProcTypes::*;
import MemTypes::*;
import RFile::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import Mmu::*;
import Tlb::*;
import Fifo::*;
import Ehr::*;
import Btb::*;
import Scoreboard::*;
import SFifo::*;
import Bht::*;
import Vector::*;
import ICache::*;
import DCache::*;
import Mul::*;
import Div::*;
import AxiTypes::*;
import AxiMem::*;
import CoreTypes::*;
import CoreFunc::*;
`include "Autoconf.bsv"
`include "CsrAddr.bsv"
`ifdef CONFIG_DIFFTEST
import DiffTypes::*;
import Difftest::*;
`endif
`ifdef CONFIG_TRACE_PERFORMANCE
import Perf::*;
`endif

interface Core;
`ifdef CONFIG_BSIM
  method ActionValue#(CpuToHostData) cpuToHost;
  method Bool cpuToHostValid;
  method Action hostToCpu(Addr startpc);
`endif
`ifdef CONFIG_DIFFTEST
  method ActionValue#(DiffTrace) diffTrace;
  method Bool diffTraceValid;
  method Bit#(142) diffCommitBundle;
  method Bit#(1024) diffRegsBundle;
  method Bit#(832) diffCsrBundle;
  method Bit#(130) diffExcpBundle;
  method Bit#(200) diffStoreBundle;
  method Bit#(136) diffLoadBundle;
  method Action diffTraceDeq;
  (* always_ready *)
  method Bool diffStepValid;
  (* always_ready *)
  method Bit#(142) liveDiffCommitBundle;
  (* always_ready *)
  method Bit#(1024) liveDiffRegsBundle;
  (* always_ready *)
  method Bit#(832) liveDiffCsrBundle;
  (* always_ready *)
  method Bit#(130) liveDiffExcpBundle;
  (* always_ready *)
  method Bit#(200) liveDiffStoreBundle;
  (* always_ready *)
  method Bit#(136) liveDiffLoadBundle;
`endif
  interface AxiMemMaster axiMem;
endinterface

(* synthesize *)
module mkCore(Core);
  Ehr#(4, Addr)         pcReg <- mkEhr(startpc);
  CsrFile                csrf <- mkCsrFile;
  RFile                    rf <- mkRFile;
  ICache               iCache <- mkICache;
  DCache               dCache <- mkDCache;
  Mul_ifc             mulUnit <- mkMul;
  Reg#(Bool)      mulInFlight <- mkReg(False);
  Div_ifc             divUnit <- mkDiv;
  Reg#(Bool)      divInFlight <- mkReg(False);
  AxiMemMaster        axiMux <- mkAxiArbiter2(iCache.axiMem, dCache.axiMem);
  Btb#(6)                 btb <- mkBtb; // 64-entry BTB
  Bht#(8)                 bht <- mkBht;
  Scoreboard#(6)           sb <- mkCFScoreboard;
  SFifo#(6, Maybe#(CsrIndx), Maybe#(CsrIndx)) csrSb <- mkCFSFifo(coreIsCsrConflict);
  Reg#(Bool)       hasIntPrev <- mkReg(False);
  TlbArray                tlb <- mkTlb;
`ifdef CONFIG_DIFFTEST
  Difftest difftest <- mkDifftest;
`endif

  // iFetch stage
  Reg#(FetchTransState) translateFetchState <- mkReg(FTransIdle);
  Reg#(FetchTransReq)  fetchReqReg <- mkRegU;
  Reg#(FetchMissCtx)  fetchMissReg <- mkRegU;
  Reg#(FetchResult) fetchResultReg <- mkRegU;
  Reg#(Bit#(4))       iCacheReqId <- mkReg(0);

  // pipeline stage fifo
  Fifo#(2, F2D)           f2dFifo <- mkCFFifo;
  Fifo#(2, D2R)           d2rFifo <- mkCFFifo;
  Fifo#(2, R2E)           r2eFifo <- mkCFFifo;
  Fifo#(2, E2M)           e2mFifo <- mkCFFifo;
  Fifo#(2, M2W)           m2wFifo <- mkCFFifo;

`ifdef CONFIG_BSIM
  Fifo#(2, CpuToHostData) toHostFifo <- mkCFFifo;
`endif
  Fifo#(2, Bool) dCacheRespSrcQ <- mkCFFifo;
  Reg#(Bool) memReqIssued <- mkReg(False);
  Reg#(Bool) memExcpPending <- mkReg(False);
  Reg#(Bool)           lrValidReg <- mkReg(False);
  Reg#(Addr)            lrAddrReg <- mkRegU;

  rule doFetchIdle (translateFetchState == FTransIdle);
    Addr pc = pcReg[0];
    Addr btbPc = btb.predPc(pc);
    Bool bhtPred = bht.predict(pc);
    Addr predPc = bhtPred ? btbPc: pc + 4;
    Data crmd = csrf.crmd;

    fetchReqReg <= FetchTransReq{
      pc: pc,
      predPc: predPc,
      crmd: crmd,
      asid: csrf.asid,
      dmw0: csrf.dmw0,
      dmw1: csrf.dmw1,
      transType: getMmuTranslateType(crmd),
      reqId: iCacheReqId
    };
    iCacheReqId <= iCacheReqId + 1;
    pcReg[0] <= predPc;
    translateFetchState <= FTransProbe;
  endrule

  rule doFetchProbe (translateFetchState == FTransProbe);
    let req = fetchReqReg;
    ICacheProbeResp probeRes = iCache.probe(req.pc);
    TlbLookupResult tlbRes = tlb.lookupFetch(req.pc, req.asid);
    MmuResult fTrans = MmuResult{
      pa: req.pc,
      mat: getFetchMatType(req.crmd),
      fromDmw: False,
      fromTlb: False,
      excValid: False,
      ecode: 0,
      esubcode: 0,
      badv: req.pc
    };

    if (req.transType == Translate) begin
      fTrans = mmuTranslate(req.pc, MmuFetch, req.crmd, req.asid, req.dmw0,
        req.dmw1, tlbRes);
    end else if (req.transType == None) begin
      fTrans.excValid = True;
      fTrans.ecode = `ECODE_ADE;
      fTrans.esubcode = `ESUBCODE_ADEF;
    end

    if (req.pc[1:0] != 2'b00) begin
      fetchResultReg <= FetchResult{
        inst: 0,
        instPaddr: 0,
        excp: mkExcp(`ECODE_ADE, `ESUBCODE_ADEF, req.pc)
      };
      translateFetchState <= FTransDone;
    end else if (fTrans.excValid) begin
      fetchResultReg <= FetchResult{
        inst: 0,
        instPaddr: 0,
        excp: mkExcp(fTrans.ecode, fTrans.esubcode, fTrans.badv)
      };
      translateFetchState <= FTransDone;
    end else begin
      Bool fetchUseCache = matUseCache(req.transType, fTrans.mat, req.crmd,MmuFetch);
      ICacheTag paTag = getITag(fTrans.pa);
      Bool hit = False;
      ICacheWayIdx hitWay = 0;
      Instruction hitInst = 0;

      for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
        if (probeRes[w].valid && probeRes[w].tag == paTag) begin
          hit = True;
          hitWay = fromInteger(w);
          hitInst = probeRes[w].inst;
        end
      end

      if (fetchUseCache && hit) begin
        iCache.commitHit(req.pc, hitWay);
        fetchResultReg <= FetchResult{
          inst: hitInst,
          instPaddr: fTrans.pa,
          excp: mkNoExcp
        };
        translateFetchState <= FTransDone;
      end else begin
        iCache.refillReq(fTrans.pa, fetchUseCache);
        fetchMissReg <= FetchMissCtx{
          pc: req.pc,
          predPc: req.predPc,
          instPaddr: fTrans.pa,
          reqId: req.reqId
        };
        translateFetchState <= FTransWaitRefill;
      end
    end
  endrule

  rule doFetchWaitRefill (translateFetchState == FTransWaitRefill);
    let miss = fetchMissReg;
    let iResp <- iCache.refillResp;
    if (iResp.addr == miss.instPaddr) begin
      fetchResultReg <= FetchResult{
        inst: iResp.inst,
        instPaddr: miss.instPaddr,
        excp: mkNoExcp
      };
      translateFetchState <= FTransDone;
    end
  endrule

  rule doFetchDone (translateFetchState == FTransDone);
    let req = fetchReqReg;
    let result = fetchResultReg;
    f2dFifo.enq(F2D{
      pc: req.pc,
      predPc: req.predPc,
      inst: result.inst,
      instPaddr: result.instPaddr,
      excp: result.excp
    });
    translateFetchState <= FTransIdle;
  endrule

  rule doDecode;
    let fetchPkt = f2dFifo.first();
    Instruction inst = fetchPkt.inst;

    f2dFifo.deq();

    DecodedInst dInst = decode(inst);
    ExcpInfo dExcp = fetchPkt.excp;
    // 检测异常(ine, syscall, break)
    if (!dExcp.valid) begin
      if (dInst.iType == Unsupported) dExcp = mkExcp(`ECODE_INE, `ESUBCODE_NONE, fetchPkt.pc);
      else if (dInst.iType == Syscall) begin
        `ifdef CONFIG_BSIM
        Bit#(9) syscallEsubcode = (inst[14:0] == 15'h11) ? 9'h001 : `ESUBCODE_NONE;
        dExcp = mkExcp(`ECODE_SYS, syscallEsubcode, fetchPkt.pc);
        `else
        `ifdef CONFIG_VSIM
        Bit#(9) syscallEsubcode = (inst[14:0] == 15'h11) ? 9'h001 : `ESUBCODE_NONE;
        dExcp = mkExcp(`ECODE_SYS, syscallEsubcode, fetchPkt.pc);
        `else
        dExcp = mkExcp(`ECODE_SYS, `ESUBCODE_NONE, fetchPkt.pc);
        `endif
        `endif
      end
      else if (dInst.iType == Break) dExcp = mkExcp(`ECODE_BRK, `ESUBCODE_NONE, fetchPkt.pc);
    end

    d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: fetchPkt.predPc,
`ifdef CONFIG_DIFFTEST
      inst: inst,
`endif
      dInst: dInst, excp: dExcp});
  endrule

  rule doRrf;
    let decodePkt = d2rFifo.first();

    let rInst = decodePkt.dInst;

    Bool isCsrWrite =(rInst.iType == Csrw || rInst.iType == Csrxchg || rInst.iType == Tlbsrch);

    Maybe#(CsrIndx) targetCsr =(rInst.iType == Tlbsrch) ? tagged Valid`CSR_TLBIDX: rInst.csr;

    Bool isTlbSerial =(rInst.iType == Tlbrd ||

    rInst.iType == Tlbwr || rInst.iType == Tlbfill || rInst.iType == Invtlb);

    Bool csrConflict = isValid(targetCsr) && csrSb.search(targetCsr);

    Bool isBarrier = coreIsBarrier(rInst.iType) || rInst.iType == Cacop;

    Bool isNeedFlush = isBarrier || isTlbSerial || isCsrWrite;

    if (!sb.search1(rInst.src1) && !sb.search2(rInst.src2) && !csrConflict) begin
      Data rVal1 = rf.rd1(fromMaybe(?, rInst.src1));
      Data rVal2 = rf.rd2(fromMaybe(?, rInst.src2));
      Data csrVal = csrf.rd(fromMaybe(?, rInst.csr));

      r2eFifo.enq(R2E{pc: decodePkt.pc, predPc: decodePkt.predPc,
`ifdef CONFIG_DIFFTEST
        inst: decodePkt.inst,
`endif
        rVal1: rVal1,
        rVal2: rVal2, csrVal: csrVal,
        isNeedFlush: isNeedFlush,
        rInst: rInst, excp: decodePkt.excp});
      csrSb.enq(isCsrWrite ? targetCsr: tagged Invalid);
      sb.insert(rInst.dst);
      d2rFifo.deq();
    end
  endrule

  rule doExec;
    let rrfPkt = r2eFifo.first();

    Bool doNormalExec = True;
    if (isValid(rrfPkt.rInst.muldivFunc)) begin
      let mdFunc = fromMaybe(?, rrfPkt.rInst.muldivFunc);
      Bool is_mul =(mdFunc == MulW || mdFunc == MulhW || mdFunc == MulhWu);
      Bool is_div =(mdFunc == DivW || mdFunc == DivWu || mdFunc == ModW || mdFunc == ModWu);
      Bool is_signed =(mdFunc == MulW || mdFunc == MulhW || mdFunc == DivW || mdFunc == ModW);

      if (is_mul) begin
        if (!mulInFlight) begin
          mulUnit.start(is_signed, rrfPkt.rVal1, rrfPkt.rVal2);
          mulInFlight <= True;
          doNormalExec = False;
        end else if (!mulUnit.finish) begin
          doNormalExec = False;
        end else begin
          mulInFlight <= False;
        end
      end else if (is_div) begin
        if (!divInFlight) begin
          divUnit.start(is_signed, rrfPkt.rVal1, rrfPkt.rVal2);
          divInFlight <= True;
          doNormalExec = False;
        end else if (!divUnit.finish) begin
          doNormalExec = False;
        end else begin
          divInFlight <= False;
        end
      end
    end

    if (!rrfPkt.excp.valid && rrfPkt.rInst.iType == Tlbsrch &&
        (e2mFifo.notEmpty || m2wFifo.notEmpty || memReqIssued ||
         dCacheRespSrcQ.notEmpty)) begin
      doNormalExec = False;
    end

    if (doNormalExec) begin
      ExecInst eInst = exec(rrfPkt.rInst, rrfPkt.rVal1, rrfPkt.rVal2, rrfPkt.pc,
      rrfPkt.predPc, rrfPkt.csrVal);
      ExcpInfo eExcp = rrfPkt.excp;
      Addr memPaddr = eInst.addr;
      Bool memUseCache = True;

      if (isValid(rrfPkt.rInst.muldivFunc)) begin
        let mdFunc = fromMaybe(?, rrfPkt.rInst.muldivFunc);
        case (mdFunc)
          MulW: eInst.data = truncate(mulUnit.result());
          MulhW, MulhWu: eInst.data = truncateLSB(mulUnit.result());
          DivW, DivWu: eInst.data = truncate(divUnit.result());
          ModW, ModWu: eInst.data = truncateLSB(divUnit.result());
        endcase
      end

      if (rrfPkt.rInst.iType == RdTimeL) begin
        eInst.data = truncate(csrf.stableCounterValue);
      end else if (rrfPkt.rInst.iType == RdTimeH) begin
        eInst.data = truncateLSB(csrf.stableCounterValue);
      end

      if (!eExcp.valid && eInst.iType == Tlbsrch) begin
        tlb.searchReq(csrf.tlbehi, csrf.asid);
      end

      if (eInst.mispredict) begin
        pcReg[1] <= eInst.addr;
        iCache.squash();
        translateFetchState <= FTransIdle;
        f2dFifo.clear();
        d2rFifo.clear();
        btb.update(rrfPkt.pc, eInst.addr);
      end
        bht.update(rrfPkt.pc, eInst.brTaken);

      ByteMask m = fromMaybe(5'b00000, rrfPkt.rInst.mask);

      Bool isMemTypeInst = eInst.iType == Ld || eInst.iType == St || eInst.iType == Ll || eInst.iType == Sc;
      if (!eExcp.valid && isMemTypeInst) begin
        Bit#(4) rawEn = m[3: 0];
        Bool exAle = False;
        if (rawEn == 4'b0011) begin
          exAle =(eInst.addr[0] != 1'b0);
        end else if (rawEn == 4'b1111) begin
          exAle =(eInst.addr[1: 0] != 2'b00);
        end
        if (exAle) eExcp = mkExcp(`ECODE_ALE, `ESUBCODE_NONE, eInst.addr);
      end

      Bool dCacheCacop = False;
      if (eInst.iType == Cacop) begin
        dCacheCacop = fromMaybe(0, eInst.cacheOp)[2:0] != 3'b000;
      end
      if (!eExcp.valid && ( isMemTypeInst || dCacheCacop )) begin
        MmuAccessType accessType =
          (eInst.iType == St || eInst.iType == Sc) ? MmuStore : MmuLoad;
        Data crmd = csrf.crmd;
        MmuTranslateType transType = getMmuTranslateType(crmd);
        TlbLookupResult tlbRes = tlb.lookupData(eInst.addr, csrf.asid);
        MmuResult dTrans = MmuResult{
          pa: eInst.addr,
          mat: getDataMatType(crmd),
          fromDmw: False,
          fromTlb: False,
          excValid: False,
          ecode: 0,
          esubcode: 0,
          badv: eInst.addr
        };
        if (transType == Translate) begin
          dTrans = mmuTranslate(eInst.addr, accessType, crmd, csrf.asid,
            csrf.dmw0, csrf.dmw1, tlbRes);
        end else if (transType == None) begin
          dTrans.excValid = True;
          dTrans.ecode = `ECODE_ADE;
          dTrans.esubcode = `ESUBCODE_ADEM;
        end
        memPaddr = dTrans.pa;
        memUseCache = matUseCache(transType, dTrans.mat, crmd, accessType);
        if (dTrans.excValid) begin
          eExcp = mkExcp(dTrans.ecode, dTrans.esubcode, dTrans.badv);
        end
      end

      r2eFifo.deq();
      e2mFifo.enq(E2M{
        pc: rrfPkt.pc,
        excp: eExcp,
        mask: rrfPkt.rInst.mask,
        memPaddr: memPaddr,
        memUseCache: memUseCache,
        isNeedFlush: rrfPkt.isNeedFlush,
        eInst: tagged Valid eInst
      });
    end
  endrule

  rule doMemoryDCacheResp (memReqIssued && e2mHasValidInst(e2mFifo.first));
    let execPkt = e2mFifo.first();
    let eInst = fromMaybe(?, execPkt.eInst);
    Bool isLoad = (eInst.iType == Ld || eInst.iType == Ll);
    Bool isStore = (eInst.iType == St);
    Bool isSc = (eInst.iType == Sc);
    Bool canIssueMem = !execPkt.excp.valid && !memExcpPending;
    ByteMask m = fromMaybe(5'b00000, execPkt.mask);
    Data storeData = eInst.data;
    let storePkt = selectStoreData(storeData, eInst.addr[1:0], m[3:0]);
    Data storeWData = tpl_2(storePkt);
    let d <- dCache.resp();

    dCacheRespSrcQ.deq();
    if (isLoad) begin
      if (eInst.iType == Ld) begin
        eInst.data = selectLoadData(d.data, eInst.addr[1:0], m[3:0], m[4] == 1'b1);
      end else begin
        eInst.data = d.data;
        lrValidReg <= True;
        lrAddrReg <= execPkt.memPaddr;
      end
    end

    e2mFifo.deq();
    memReqIssued <= False;
    hasIntPrev <= coreHasInterrupt(csrf.crmd, csrf.ecfg, csrf.estat);
    if (canIssueMem && (isStore || isSc)) begin
      lrValidReg <= False;
    end

    `ifdef CONFIG_DIFFTEST
    Maybe#(DiffMemOp) diffMemInfo = tagged Invalid;
    if (canIssueMem && (isLoad || isStore || isSc)) begin
      diffMemInfo = tagged Valid DiffMemOp{
        isLoad: isLoad,
        isStore: isStore || isSc,
        isSc: isSc,
        paddr: execPkt.memPaddr,
        vaddr: eInst.addr,
        storeData: storeWData
      };
    end
    `endif
    m2wFifo.enq(M2W{
      pc: execPkt.pc,
`ifdef CONFIG_DIFFTEST
      inst: execPkt.inst,
`endif
      excp: execPkt.excp,
      memPaddr: execPkt.memPaddr,
      isNeedFlush: execPkt.isNeedFlush,
      mInst: tagged Valid eInst
`ifdef CONFIG_DIFFTEST
      , diffMem: diffMemInfo
`endif
    });
  endrule

  rule doMemoryTlbsrchResp (!memReqIssued && !memExcpPending &&
      e2mNeedsTlbsrchResp(e2mFifo.first));
    let execPkt = e2mFifo.first();
    let eInst = fromMaybe(?, execPkt.eInst);
    let res <- tlb.searchResp;
    csrf.applyTlbsrchResult(res);
    hasIntPrev <= coreHasInterrupt(csrf.crmd, csrf.ecfg, csrf.estat);
    e2mFifo.deq();
    m2wFifo.enq(M2W{
      pc: execPkt.pc,
`ifdef CONFIG_DIFFTEST
      inst: execPkt.inst,
`endif
      excp: execPkt.excp,
      memPaddr: execPkt.memPaddr,
      isNeedFlush: execPkt.isNeedFlush,
      mInst: tagged Valid eInst
`ifdef CONFIG_DIFFTEST
      , diffMem: tagged Invalid
`endif
    });
  endrule

  rule doMemoryDCacheReq (!memReqIssued && e2mMayUseDCache(e2mFifo.first));
    let execPkt = e2mFifo.first();
    let eInst = fromMaybe(?, execPkt.eInst);
      Bool memReady = True;
      Bool isLoad = (eInst.iType == Ld || eInst.iType == Ll);
      Bool isStore = (eInst.iType == St);
      Bool isSc = (eInst.iType == Sc);
      Bool isBarrier = coreIsBarrier(eInst.iType);
      Bool isCacop = (eInst.iType == Cacop);
      Bool cacopNeedsDCache = isCacop && fromMaybe(0, eInst.cacheOp)[2:0] != 3'b000;
      Bool memDCacheSideEffect =
        isStore || isSc || isBarrier || cacopNeedsDCache;
      Bool memIsCsrWrite = (eInst.iType == Csrw || eInst.iType == Csrxchg);
      let intCsrView = coreInterruptCsrView(
        memIsCsrWrite ? eInst.csr : tagged Invalid, eInst.addr, csrf.crmd,
        csrf.ecfg, csrf.estat);
      Data memCrmd = tpl_1(intCsrView);
      Data memEcfg = tpl_2(intCsrView);
      Data memEstat = tpl_3(intCsrView);
      Data pendingInterruptBits = corePendingInterruptBits(memEcfg, memEstat);
      Bool timerPending = ((pendingInterruptBits & 32'h00000800) != 0);
      Bool softPending = ((pendingInterruptBits & 32'h00000003) != 0);
      Bool delayInterrupt = timerPending && !softPending;
      Bool has_int_raw = coreHasInterrupt(memCrmd, memEcfg, memEstat);
      Bool hasPendingDCacheResp = dCacheRespSrcQ.notEmpty;
      Bool has_int = !memDCacheSideEffect && !memReqIssued && !hasPendingDCacheResp &&
        has_int_raw && (!delayInterrupt || hasIntPrev);
      ExcpInfo memExcp = has_int ? mkExcp(`ECODE_INT, 0, 0) : execPkt.excp;
      Bool canIssueMem = !memExcp.valid && !memExcpPending;
      ByteMask m = fromMaybe(5'b00000, execPkt.mask);
      Data storeData = eInst.data;
      let storePkt = selectStoreData(storeData, eInst.addr[1:0], m[3:0]);
      Bit#(WordSz) storeByteEn = tpl_1(storePkt);
      Data storeWData = tpl_2(storePkt);

      hasIntPrev <= has_int_raw;

      if (memExcp.valid) begin
        memExcpPending <= True;
      end

      if (canIssueMem && isSc) begin
        eInst.data = (lrValidReg && lrAddrReg == execPkt.memPaddr) ? scSucc : scFail;
      end

      Bool scStore = isSc && eInst.data == scSucc;
      Bool needsDCache = canIssueMem &&
        (isLoad || isStore || scStore || isBarrier || cacopNeedsDCache);

      if (needsDCache) begin
        if (!memReqIssued) begin
          if (!m2wFifo.notEmpty && !dCacheRespSrcQ.notEmpty) begin
            Bit#(WordSz) byteEn = 4'b0000;
            Data wData = 0;
            MemOp memOp = Ld;

            if (isStore || scStore) begin
              byteEn = storeByteEn;
              wData = storeWData;
              memOp = St;
            end else if (isBarrier) begin
              memOp = Barrier;
            end else if (cacopNeedsDCache) begin
              memOp = Cacop;
            end

            dCache.req(MemReq {
              op: memOp,
              addr: eInst.addr,
              paddr: execPkt.memPaddr,
              useCache: (memOp == Cacop || memOp == Barrier) ? True : execPkt.memUseCache,
              data: wData,
              byteEn: byteEn,
              cacheOp: isCacop ? fromMaybe(0, eInst.cacheOp) : 5'b0
            });
            dCacheRespSrcQ.enq(True);
            memReqIssued <= True;
          end
          memReady = False;
        end
      end

      if (memReady) begin
        e2mFifo.deq();
        if (memReqIssued) begin
          memReqIssued <= False;
        end
        if (canIssueMem && (isStore || isSc)) begin
          lrValidReg <= False;
        end

        `ifdef CONFIG_DIFFTEST
        // diffMemInfo
        // TODO:
        Maybe#(DiffMemOp) diffMemInfo = tagged valid {};
        `endif
        m2wFifo.enq(M2W{
          pc: execPkt.pc,
          excp: memExcp,
          memPaddr: execPkt.memPaddr,
          isNeedFlush: execPkt.isNeedFlush,
          mInst: tagged Valid eInst
`ifdef CONFIG_DIFFTEST
          , diffMem: diffMemInfo;
`endif
        });
      end
  endrule

  rule doMemoryBypass (!memReqIssued && !e2mMayUseDCache(e2mFifo.first) &&
      (memExcpPending || !e2mNeedsTlbsrchResp(e2mFifo.first)));
    let execPkt = e2mFifo.first();
    if (isValid(execPkt.eInst)) begin
      let eInst = fromMaybe(?, execPkt.eInst);
      Bool isTlbsrch = (eInst.iType == Tlbsrch);
      Bool memDCacheSideEffect = isTlbsrch;
      Bool memIsCsrWrite = (eInst.iType == Csrw || eInst.iType == Csrxchg);
      let intCsrView = coreInterruptCsrView(
        memIsCsrWrite ? eInst.csr : tagged Invalid, eInst.addr, csrf.crmd,
        csrf.ecfg, csrf.estat);
      Data memCrmd = tpl_1(intCsrView);
      Data memEcfg = tpl_2(intCsrView);
      Data memEstat = tpl_3(intCsrView);
      Data pendingInterruptBits = corePendingInterruptBits(memEcfg, memEstat);
      Bool timerPending = ((pendingInterruptBits & 32'h00000800) != 0);
      Bool softPending = ((pendingInterruptBits & 32'h00000003) != 0);
      Bool delayInterrupt = timerPending && !softPending;
      Bool has_int_raw = coreHasInterrupt(memCrmd, memEcfg, memEstat);
      Bool has_int = !memDCacheSideEffect && !memReqIssued && !dCacheRespSrcQ.notEmpty &&
        has_int_raw && (!delayInterrupt || hasIntPrev);
      ExcpInfo memExcp = has_int ? mkExcp(`ECODE_INT, 0, 0) : execPkt.excp;

      hasIntPrev <= has_int_raw;
      if (memExcp.valid) begin
        memExcpPending <= True;
      end

      e2mFifo.deq();
      m2wFifo.enq(M2W{
        pc: execPkt.pc,
`ifdef CONFIG_DIFFTEST
        inst: execPkt.inst,
`endif
        excp: memExcp,
        memPaddr: execPkt.memPaddr,
        isNeedFlush: execPkt.isNeedFlush,
        mInst: tagged Valid eInst
`ifdef CONFIG_DIFFTEST
        , diffMem: tagged Invalid
`endif
      });
    end else begin
      e2mFifo.deq();
      m2wFifo.enq(M2W{
        pc: execPkt.pc,
        excp: execPkt.excp,
        memPaddr: execPkt.memPaddr,
        isNeedFlush: execPkt.isNeedFlush,
        mInst: tagged Invalid
`ifdef CONFIG_DIFFTEST
        , diffMem: tagged Invalid
`endif
      });
    end
  endrule

  rule doWriteback;
    let memPkt = m2wFifo.first();
    Bool wbRetire = False;
    Bool wbFlush = False;

    if (isValid(memPkt.mInst)) begin
      let mInst = fromMaybe(?, memPkt.mInst);
      Bool wbReady = True;
      Bool isCacop = (mInst.iType == Cacop);

      ExcpInfo wbExcp = memPkt.excp;
      Bool wb_finish_on_syscall = False;
      Bool has_int = memPkt.excp.valid && memPkt.excp.ecode == `ECODE_INT;
`ifdef CONFIG_BSIM
      wb_finish_on_syscall = (!has_int) && wbExcp.valid &&
        (wbExcp.ecode == `ECODE_SYS) && (wbExcp.esubcode == 9'h001);
`endif
      Bool wb_has_excp = wbExcp.valid && !wb_finish_on_syscall;
      Bit#(6) wb_ecode = wbExcp.ecode;
      Bit#(9) wb_esubcode = wbExcp.esubcode;
      Addr ertnTarget = 0;
      Bool wbNeedsFlush = wb_has_excp || ((!wb_has_excp) && mInst.iType == Ertn);
      Bit#(5) wbTlbfillIndex = 0;

      if (wbReady) begin
        Bool wen = False;
        Bool wbIsCsrWrite =(mInst.iType == Csrw || mInst.iType == Csrxchg);
        if (wb_has_excp) begin
          Addr exEntry <- csrf.raiseException(wb_ecode, wb_esubcode, memPkt.pc, wbExcp.badv);
          pcReg[2] <= exEntry;
          wbFlush = True;
        end else begin
`ifdef CONFIG_BSIM
          if (wb_finish_on_syscall) begin
            $display("this syscall 0x11, finish simulation");
            toHostFifo.enq(CpuToHostData{
              c2hType: ExitCode,
              data: 16'b0
            });
          end
`endif
          if (isValid(mInst.dst)) begin
            rf.wr(fromMaybe(?, mInst.dst), mInst.data);
            wen =(fromMaybe(0, mInst.dst) != 0);
          end
          if (mInst.iType == Ertn) begin
            Addr era <- csrf.returnFromException;
            ertnTarget = era;
            pcReg[2] <= era;
            wbFlush = True;
          end else if (mInst.iType == Tlbsrch) begin
            noAction;
          end else if (mInst.iType == Invtlb) begin
            tlb.invtlb(truncate(fromMaybe(0, mInst.imm)), mInst.data, mInst.addr);
          end else if (mInst.iType == Tlbwr) begin
            tlb.writeEntry(csrf.tlbWriteIdx, csrf.tlbWriteEhi, csrf.tlbWriteElo0,
              csrf.tlbWriteElo1, csrf.tlbWriteAsid);
            csrf.commitTlbOp;
          end else if (mInst.iType == Tlbfill) begin
            let idx <- tlb.fillEntry(csrf.tlbWriteIdx, csrf.tlbWriteEhi,
              csrf.tlbWriteElo0, csrf.tlbWriteElo1, csrf.tlbWriteAsid);
            wbTlbfillIndex = zeroExtend(idx);
            csrf.commitTlbOp;
          end else if (mInst.iType == Tlbrd) begin
            let tlbRead = tlb.readEntry(csrf.tlbReadIndex);
            csrf.applyTlbrdResult(tlbRead.ne, tlbRead.ps, tlbRead.ehi,
              tlbRead.elo0, tlbRead.elo1, tlbRead.asid);
          end else if (mInst.iType == Ibar) begin
            iCache.invalidate;
          end else if (isCacop && fromMaybe(0, mInst.cacheOp)[2:0] == 3'b000) begin
            iCache.cacop(fromMaybe(0, mInst.cacheOp), mInst.addr, mInst.data);
          end else begin
            csrf.wr(wbIsCsrWrite ? mInst.csr: Invalid, wbIsCsrWrite ? mInst.addr: mInst.data);
          end

          if (!wbFlush && memPkt.isNeedFlush) begin
            pcReg[3] <= memPkt.pc + 4;
            wbFlush = True;
          end
        end

        if (!wbFlush) begin
          wbRetire = True;
`ifdef CONFIG_DIFFTEST
          Bool diffCommitErtn = (!wb_has_excp) && (mInst.iType == Ertn);
          Addr commitNextPc = diffCommitErtn ? ertnTarget : (mInst.mispredict ? mInst.addr : (memPkt.pc + 4));

          Maybe#(RIndx) diffDst = tagged Invalid;
          Maybe#(CsrIndx) diffCsrIdx = tagged Invalid;
          Data diffCsrVal = mInst.data;
          if (wen && isValid(mInst.dst)) begin
            diffDst = mInst.dst;
          end
          if (!wb_has_excp) begin
            if (mInst.iType == Tlbsrch) begin
              diffCsrIdx = tagged Valid `CSR_TLBIDX;
              diffCsrVal = csrf.tlbidx;
            end else if (mInst.iType == Csrw || mInst.iType == Csrxchg) begin
              diffCsrIdx = mInst.csr;
              diffCsrVal = mInst.addr;
            end
          end

          DiffStoreEvent storeEvent = DiffStoreEvent{
            valid: 0,
            paddr: 0,
            vaddr: 0,
            data: 0
          };
          DiffLoadEvent loadEvent = DiffLoadEvent{
            valid: 0,
            paddr: 0,
            vaddr: 0
          };

          if (!wb_has_excp) begin
            if (memPkt.diffMem matches tagged Valid .diffMem) begin
              if (diffMem.isStore && (!diffMem.isSc || mInst.data == scSucc)) begin
                storeEvent = DiffStoreEvent{
                  valid: diffStoreCode(mInst.iType, fromMaybe(5'b0, mInst.mask)[3:0], mInst.data == scSucc),
                  paddr: zeroExtend(diffMem.paddr),
                  vaddr: zeroExtend(diffMem.vaddr),
                  data: zeroExtend(diffMem.storeData)
                };
              end
              if (diffMem.isLoad) begin
                loadEvent = DiffLoadEvent{
                  valid: diffLoadCode(mInst.iType, mInst.mask),
                  paddr: zeroExtend(diffMem.paddr),
                  vaddr: zeroExtend(diffMem.vaddr)
                };
              end
            end
          end

          let diffRegsState = rf.diffSnapshotAfterWrite(diffDst, mInst.data);

          let diffCsrState =
          (mInst.iType == Tlbrd) ?
          csrf.diffSnapshotAfterTlbrd(tlb.readEntry(csrf.tlbReadIndex).ne, tlb.readEntry(csrf.tlbReadIndex).ps, tlb.readEntry(csrf.tlbReadIndex).ehi, tlb.readEntry(csrf.tlbReadIndex).elo0, tlb.readEntry(csrf.tlbReadIndex).elo1, tlb.readEntry(csrf.tlbReadIndex).asid):
          csrf.diffSnapshotAfterWrite(
          diffCsrIdx,
          diffCsrVal,
          wb_has_excp,
          wb_ecode,
          wb_esubcode,
          memPkt.pc,
          wbExcp.badv,
          diffCommitErtn
          );

          let diffCommitState = DiffCommit{
            valid: !wb_has_excp,
            pc: memPkt.pc,
            nextPc: commitNextPc,
            inst: memPkt.inst,
            wen: wen,
            wdest: fromMaybe(0, mInst.dst),
            wdata: mInst.data,
            skip: False,
            isTlbfill: (!wb_has_excp) && (mInst.iType == Tlbfill),
            tlbfillIndex: wbTlbfillIndex
          };
          let diffExcpState = DiffExcpEvent{
            excpValid: wb_has_excp,
            eret: (mInst.iType == Ertn),
            interrupt: mkInterruptNo(csrf.estat),
            exception: has_int ? 0 : zeroExtend(wbExcp.ecode),
            exceptionPC: memPkt.pc,
            exceptionInst: memPkt.inst
          };

          difftest.enqTrace(DiffTrace{
            commit: diffCommitState,
            regs: diffRegsState,
            csr: diffCsrState,
            excp: diffExcpState,
            store: storeEvent,
            load: loadEvent
          });
`endif
        end
      end
    end else begin
      wbRetire = True;
    end

    if (wbFlush) begin
      lrValidReg <= False;
      iCache.squash();
      dCache.squash();
      dCacheRespSrcQ.clear();
      memReqIssued <= False;
      memExcpPending <= False;
      f2dFifo.clear();
      d2rFifo.clear();
      r2eFifo.clear();
      e2mFifo.clear();
      m2wFifo.clear();
      csrSb.clear();
      sb.clear();
      // A flushed younger mul/div may have started the iterative unit but never
      // reach the retire path that clears these in-flight flags.
      mulInFlight <= False;
      divInFlight <= False;
`ifdef CONFIG_DIFFTEST
      difftest.clearLive;
`endif
    end else if (wbRetire) begin
      if (isValid(memPkt.mInst)) begin
        let retiredType = fromMaybe(?, memPkt.mInst).iType;
      end
      m2wFifo.deq();
      csrSb.deq();
      sb.remove();
      `ifdef CONFIG_TRACE_PERFORMANCE
        inst_count();
      `endif
    end
  endrule

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
  method ActionValue#(DiffTrace) diffTrace;
    let ret <- difftest.diffTrace;
    return ret;
  endmethod
  method Bool diffTraceValid = difftest.diffTraceValid;
  method Bit#(142) diffCommitBundle = difftest.diffCommitBundle;
  method Bit#(1024) diffRegsBundle = difftest.diffRegsBundle;
  method Bit#(832) diffCsrBundle = difftest.diffCsrBundle;
  method Bit#(130) diffExcpBundle = difftest.diffExcpBundle;
  method Bit#(200) diffStoreBundle = difftest.diffStoreBundle;
  method Bit#(136) diffLoadBundle = difftest.diffLoadBundle;
  method Action diffTraceDeq;
    difftest.diffTraceDeq;
  endmethod
  method Bool diffStepValid = difftest.diffStepValid;
  method Bit#(142) liveDiffCommitBundle = difftest.liveDiffCommitBundle;
  method Bit#(1024) liveDiffRegsBundle = difftest.liveDiffRegsBundle;
  method Bit#(832) liveDiffCsrBundle = difftest.liveDiffCsrBundle;
  method Bit#(130) liveDiffExcpBundle = difftest.liveDiffExcpBundle;
  method Bit#(200) liveDiffStoreBundle = difftest.liveDiffStoreBundle;
  method Bit#(136) liveDiffLoadBundle = difftest.liveDiffLoadBundle;
`endif

  interface axiMem = axiMux;
endmodule
