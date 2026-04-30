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
  Ehr#(3, Addr)         pcReg <- mkEhr(startpc);
  CsrFile                csrf <- mkCsrFile;
  RFile                    rf <- mkBypassRFile;
  ICache               iCache <- mkICache;
  DCache               dCache <- mkDCache;
  Mul_ifc             mulUnit <- mkMul;
  Reg#(Bool)      mulInFlight <- mkReg(False);
  Div_ifc             divUnit <- mkDiv;
  Reg#(Bool)      divInFlight <- mkReg(False);
  AxiMemMaster        axiMux <- mkAxiArbiter2(iCache.axiMem, dCache.axiMem);
  Btb#(6)                 btb <- mkBtb; // 64-entry BTB
  Bht#(8)                 bht <- mkBht;
  Scoreboard#(8)        regSb <- mkCFScoreboard;
  SFifo#(8, Maybe#(CsrIndx), Maybe#(CsrIndx)) csrSb <- mkCFSFifo(coreIsCsrConflict);
  Reg#(Bool)         idleLock <- mkReg(False);
  TlbArray                tlb <- mkTlb;
`ifdef CONFIG_DIFFTEST
  Difftest difftest <- mkDifftest;
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

  // 7-stage pipeline FIFOs
  Fifo#(2, F1toF2)       f1f2Fifo <- mkCFFifo;  // IF1 -> IF2
  Fifo#(2, F2D)            f2dFifo <- mkCFFifo;  // IF2 -> ID
  Fifo#(2, D2R)            d2rFifo <- mkCFFifo;  // ID -> RR
  Fifo#(2, R2E)            r2eFifo <- mkCFFifo;  // RR -> EXE
  Fifo#(2, E2M)            e2mFifo <- mkCFFifo;  // EXE -> MEM
  Fifo#(2, M1toM2)        m1m2Fifo <- mkCFFifo;  // MEM1 -> MEM2
  Fifo#(2, M2W)            m2wFifo <- mkCFFifo;  // MEM -> WB

  // I-Cache miss tracking: IF2 waits for refill
  Reg#(Bool)        if2WaitRefill <- mkReg(False);
  Reg#(F1toF2)       if2PendingReq <- mkRegU;
  Reg#(Addr)         if2MissPaddr  <- mkRegU;

`ifdef CONFIG_BSIM
  Fifo#(2, CpuToHostData) toHostFifo <- mkCFFifo;
`endif
  Reg#(Bool) memRedirectPending <- mkReg(False);

  // ============================================================
  // Stage 1: IF1 — PC selection, start I-Cache probe, start I-TLB lookup
  // ============================================================
`ifdef CONFIG_TRACE_PERFORMANCE
  rule countIfStall (!f1f2Fifo.notFull);
    perf_pipeline_stall(0);
  endrule

  rule countExStall(!e2mFifo.notFull);
    perf_pipeline_stall(2);
  endrule
`endif

  function Action doIF1Body(Addr pc, Data crmd, Data asid, MmuTranslateType transType);
    action
    Addr btbPc = btb.predPc(pc);
    Bool bhtPred = bht.predict(pc);
    Addr predPc = bhtPred ? btbPc : pc + 4;

    f1f2Fifo.enq(F1toF2{
      pc: pc,
      predPc: predPc,
      crmd: crmd,
      asid: asid,
      dmw0: csrf.dmw0,
      dmw1: csrf.dmw1,
      transType: transType,
      probeRes: iCache.probe(pc)
    });
    pcReg[0] <= predPc;
    endaction
  endfunction

  rule releaseIdleOnInterrupt (idleLock && csrf.interruptDetected);
    idleLock <= False;
  endrule

  rule doIF1NoFetchTlb (!idleLock && getMmuTranslateType(csrf.crmd) != Translate);
    doIF1Body(pcReg[0], csrf.crmd, csrf.asid, getMmuTranslateType(csrf.crmd));
  endrule

  rule doIF1WithFetchTlb (!idleLock && getMmuTranslateType(csrf.crmd) == Translate);
    Addr pc = pcReg[0];
    Data asid = csrf.asid;
    tlb.fetchLookupReq(pc, asid);
    doIF1Body(pc, csrf.crmd, asid, Translate);
  endrule

  // ============================================================
  // Stage 2: IF2 — I-Cache tag match, instruction selection, I-MMU result
  // ============================================================
  rule doIF2if2WaitRefill (if2WaitRefill);
    let req = if2PendingReq;
    let iResp <- iCache.refillResp;
`ifdef CONFIG_TRACE_PERFORMANCE
    perf_icache_miss_cycle();
`endif
    if (iResp.addr == if2MissPaddr) begin
      f2dFifo.enq(F2D{
        pc: req.pc,
        predPc: req.predPc,
        inst: iResp.inst,
        instPaddr: if2MissPaddr,
        excp: mkNoExcp
      });
      if2WaitRefill <= False;
      f1f2Fifo.deq();
    end
  endrule

  function Action doIF2Body(TlbLookupResult tlbRes);
    action
    let req = f1f2Fifo.first();
    ICacheProbeResp probeRes = req.probeRes;
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
      f2dFifo.enq(F2D{
        pc: req.pc,
        predPc: req.predPc,
        inst: 0,
        instPaddr: 0,
        excp: mkExcp(`ECODE_ADE, `ESUBCODE_ADEF, req.pc)
      });
      f1f2Fifo.deq();
    end else if (fTrans.excValid) begin
      f2dFifo.enq(F2D{
        pc: req.pc,
        predPc: req.predPc,
        inst: 0,
        instPaddr: 0,
        excp: mkExcp(fTrans.ecode, fTrans.esubcode, fTrans.badv)
      });
      f1f2Fifo.deq();
    end else begin
      Bool fetchUseCache = matUseCache(req.transType, fTrans.mat, req.crmd, MmuFetch);
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
        f2dFifo.enq(F2D{
          pc: req.pc,
          predPc: req.predPc,
          inst: hitInst,
          instPaddr: fTrans.pa,
          excp: mkNoExcp
        });
        f1f2Fifo.deq();
      end else begin
        // Cache miss: issue refill and stall IF2
        // Do NOT dequeue f1f2Fifo — keep entry until refill completes
`ifdef CONFIG_TRACE_PERFORMANCE
        perf_icache_miss();
`endif
        iCache.refillReq(fTrans.pa, fetchUseCache);
        if2PendingReq <= req;
        if2MissPaddr <= fTrans.pa;
        if2WaitRefill <= True;
      end
    end
    endaction
  endfunction

  rule doIF2NoFetchTlb (!if2WaitRefill &&
      f1f2Fifo.first.transType != Translate);
    doIF2Body(noTlbLookup);
  endrule

  rule doIF2WithFetchTlb (!if2WaitRefill &&
      f1f2Fifo.first.transType == Translate);
    let tlbRes <- tlb.fetchLookupResp;
    doIF2Body(tlbRes);
  endrule

  // ============================================================
  // Stage 3: ID — Instruction decode, simple J/B resolution, scoreboard
  // ============================================================
  rule doDecode;
    let fetchPkt = f2dFifo.first();
    Instruction inst = fetchPkt.inst;

    f2dFifo.deq();

    DecodedInst dInst = decode(inst);
    ExcpInfo dExcp = fetchPkt.excp;
    if (!dExcp.valid) begin
      if (dInst.iType == Unsupported) dExcp = mkExcp(`ECODE_INE, `ESUBCODE_NONE, fetchPkt.pc);
      else if (dInst.iType == Syscall) begin
        `ifdef CONFIG_BSIM
        Bit#(9) syscallEsubcode = (inst[14:0] == 15'h11) ? 9'h001 : `ESUBCODE_NONE;
        dExcp = mkExcp(`ECODE_SYS, syscallEsubcode, fetchPkt.pc);
        `else
        dExcp = mkExcp(`ECODE_SYS, `ESUBCODE_NONE, fetchPkt.pc);
        `endif
      end
      else if (dInst.iType == Break) dExcp = mkExcp(`ECODE_BRK, `ESUBCODE_NONE, fetchPkt.pc);
    end

    d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: fetchPkt.predPc,
`ifdef CONFIG_DIFFTEST
      inst: inst,
`else
`ifdef CONFIG_WB_DEBUG_INST
      inst: inst,
`endif
`endif
      dInst: dInst, excp: dExcp});
  endrule

  // ============================================================
  // Stage 4: RR — Register File read, CSR read, forwarding logic
  // ============================================================
  function Bool rrfHasHazard(D2R decodePkt);
    let rInst = decodePkt.dInst;

    Bool isCsrWrite = rrfIsCsrWrite(rInst);
    Maybe#(CsrIndx) targetCsr = rrfTargetCsr(rInst);

    Bool csrConflict = isValid(targetCsr) && csrSb.search(targetCsr);

    ScoreboardSearchResult src1Sb = regSb.search1(rInst.src1);
    ScoreboardSearchResult src2Sb = regSb.search2(rInst.src2);

    Bool src1Hazard = src1Sb.found && !isValid(src1Sb.data);
    Bool src2Hazard = src2Sb.found && !isValid(src2Sb.data);

    return csrConflict || src1Hazard || src2Hazard;
  endfunction

  `ifdef CONFIG_TRACE_PERFORMANCE
  rule countRfStall (d2rFifo.notEmpty() && rrfHasHazard(d2rFifo.first()));
    perf_pipeline_stall(1);
  endrule
  `endif

  rule doRrf (d2rFifo.notEmpty() && !rrfHasHazard(d2rFifo.first()));
    let decodePkt = d2rFifo.first();
    let rInst = decodePkt.dInst;

    Bool isCsrWrite = rrfIsCsrWrite(rInst);
    Bool updatesLlbctl = (rInst.iType == Ll || rInst.iType == Sc);
    Maybe#(CsrIndx) targetCsr = rrfTargetCsr(rInst);

    Bool isTlbSerial = rInst.iType == Tlbrd ||
      rInst.iType == Tlbwr || rInst.iType == Tlbfill || rInst.iType == Invtlb;

    Bool isBarrier = coreIsBarrier(rInst.iType) || rInst.iType == Cacop;
    Bool isNeedFlush = isBarrier || isTlbSerial || isCsrWrite || updatesLlbctl;

    ScoreboardSearchResult src1Sb = regSb.search1(rInst.src1);
    ScoreboardSearchResult src2Sb = regSb.search2(rInst.src2);

    Data rVal1 = rf.rd1(fromMaybe(?, rInst.src1));
    Data rVal2 = rf.rd2(fromMaybe(?, rInst.src2));
    Data csrVal = csrf.rd(fromMaybe(?, rInst.csr));

    if (rInst.src1 matches tagged Valid .s1 &&& s1 == 0) begin
      rVal1 = 0;
    end else if (src1Sb.found &&& src1Sb.data matches tagged Valid .fwdData1) begin
      rVal1 = fwdData1;
    end

    if (rInst.src2 matches tagged Valid .s2 &&& s2 == 0) begin
      rVal2 = 0;
    end else if (src2Sb.found &&& src2Sb.data matches tagged Valid .fwdData2) begin
      rVal2 = fwdData2;
    end

    ScoreboardTag sbTag = regSb.enqTag;
    r2eFifo.enq(R2E{
      pc: decodePkt.pc,
      predPc: decodePkt.predPc,
  `ifdef CONFIG_DIFFTEST
      inst: decodePkt.inst,
  `else
  `ifdef CONFIG_WB_DEBUG_INST
      inst: decodePkt.inst,
  `endif
  `endif
      rVal1: rVal1,
      rVal2: rVal2,
      csrVal: csrVal,
      isNeedFlush: isNeedFlush,
      sbTag: sbTag,
      rInst: rInst,
      excp: decodePkt.excp
    });

    regSb.insert(rInst.dst);
    csrSb.enq((isCsrWrite || updatesLlbctl) ? targetCsr : tagged Invalid);
    d2rFifo.deq();
  endrule

  // ============================================================
  // Stage 5: EXE — ALU, AGU, Mul/Div start, Branch resolution
  // D-MMU translation is REMOVED from this stage (moved to MEM)
  // ============================================================
  rule doExec;
    let rrfPkt = r2eFifo.first();

    Bool doNormalExec = True;
    if (!rrfPkt.excp.valid && isValid(rrfPkt.rInst.muldivFunc)) begin
      let mdFunc = fromMaybe(?, rrfPkt.rInst.muldivFunc);
      Bool is_mul = (mdFunc == MulW || mdFunc == MulhW || mdFunc == MulhWu);
      Bool is_div = (mdFunc == DivW || mdFunc == DivWu || mdFunc == ModW || mdFunc == ModWu);
      Bool is_signed = (mdFunc == MulW || mdFunc == MulhW || mdFunc == DivW || mdFunc == ModW);

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

    if (doNormalExec) begin
      ExecInst eInst = exec(rrfPkt.rInst, rrfPkt.rVal1, rrfPkt.rVal2, rrfPkt.pc,
      rrfPkt.predPc, rrfPkt.csrVal);
      ExcpInfo eExcp = rrfPkt.excp;

`ifdef CONFIG_TRACE_PERFORMANCE
      if (rrfPkt.rInst.iType == Br) begin
        perf_branch_exec(eInst.mispredict);
      end
`endif

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

      if (eInst.mispredict) begin
        pcReg[1] <= eInst.targetAddr;
        iCache.squash();
        tlb.squashFetchLookup();
        f1f2Fifo.clear();
        f2dFifo.clear();
        d2rFifo.clear();
        r2eFifo.clear();
        regSb.redirect(rrfPkt.sbTag);
        csrSb.redirect(rrfPkt.sbTag);
        if2WaitRefill <= False;
        btb.update(rrfPkt.pc, eInst.targetAddr);
      end
      bht.update(rrfPkt.pc, eInst.brTaken);

      // Alignment check for memory operations
      Bool isMemTypeInst = eInst.iType == Ld || eInst.iType == St || eInst.iType == Ll || eInst.iType == Sc;
      Bool isTlbSerial = (eInst.iType == Tlbsrch || eInst.iType == Tlbrd ||
            eInst.iType == Tlbwr || eInst.iType == Tlbfill || eInst.iType == Invtlb);
      ByteMask m = fromMaybe(5'b00000, rrfPkt.rInst.mask);
      if (isMemTypeInst) begin
        eExcp = checkMemHasExcp(rrfPkt.rInst.mask, eInst.addr, eExcp);
      end

      Bit#(5) execCacheOp = fromMaybe(0, eInst.cacheOp);
      Bool dCacheCacop = (eInst.iType == Cacop) && execCacheOp[2:0] != 3'b000;
      Bool iCacheCacop = (eInst.iType == Cacop) && execCacheOp[2:0] == 3'b000;
      Bool dataTlbLookupPending = (isMemTypeInst || dCacheCacop || iCacheCacop) &&
        getMmuTranslateType(csrf.crmd) == Translate;
      if (dataTlbLookupPending) begin
        tlb.dataLookupReq(eInst.addr, csrf.asid);
      end

      r2eFifo.deq();
      Maybe#(Data) exeResult = (isValid(eInst.dst) && !isMemTypeInst &&
        !isTlbSerial) ? tagged Valid eInst.data : tagged Invalid;
      regSb.updateExe(rrfPkt.sbTag, exeResult);
      // E2M no longer carries memPaddr/memUseCache — those are computed in MEM
      e2mFifo.enq(E2M{
        pc: rrfPkt.pc,
`ifdef CONFIG_DIFFTEST
        inst: rrfPkt.inst,
`else
`ifdef CONFIG_WB_DEBUG_INST
        inst: rrfPkt.inst,
`endif
`endif
        excp: eExcp,
        mask: rrfPkt.rInst.mask,
        isNeedFlush: rrfPkt.isNeedFlush,
        dataTlbLookupPending: dataTlbLookupPending,
        sbTag: rrfPkt.sbTag,
        eInst: tagged Valid eInst
      });
    end
  endrule

  // ============================================================
  // Stage 6a/6b: MEM1 dispatch and MEM2 response collection
  // ============================================================
`ifdef CONFIG_TRACE_PERFORMANCE
  rule countMemStall (e2mFifo.notEmpty && !m1m2Fifo.notFull);
    perf_pipeline_stall(3);
  endrule
`endif

  function Action doMemoryStage1Body(TlbLookupResult tlbRes);
    action
    let execPkt = e2mFifo.first();
    Mem2Op nextOp = M2OpNone;
    Addr memPaddr = 0;
    ExcpInfo memExcp = execPkt.excp;
    Maybe#(ExecInst) nextInst = execPkt.eInst;

    if (execPkt.eInst matches tagged Valid .eInst) begin
      ExecInst memInst = eInst;
      Bool isLoad = (eInst.iType == Ld || eInst.iType == Ll);
      Bool isStore = (eInst.iType == St);
      Bool isSc = (eInst.iType == Sc);
      Bool isBarrier = coreIsBarrier(eInst.iType);
      Bool isCacop = (eInst.iType == Cacop);
      Bit#(5) cacheOp = fromMaybe(0, eInst.cacheOp);
      Bool cacopNeedsICache = isCacop && cacheOp[2:0] == 3'b000;
      Bool cacopNeedsDCache = isCacop && cacheOp[2:0] != 3'b000;
      Bool isTlbOp = (eInst.iType == Tlbsrch || eInst.iType == Tlbrd ||
        eInst.iType == Tlbwr || eInst.iType == Tlbfill || eInst.iType == Invtlb);
      Bool memDCacheSideEffect = isStore || isSc || isBarrier ||
        cacopNeedsDCache || cacopNeedsICache || isTlbOp;
      Bool memIsCsrWrite = (eInst.iType == Csrw || eInst.iType == Csrxchg);
      Bool has_int = csrf.hasInterrupt(memIsCsrWrite ? eInst.csr : tagged Invalid,
        eInst.addr, memDCacheSideEffect);
      memExcp = has_int ? mkExcp(`ECODE_INT, 0, 0) : execPkt.excp;
      if (has_int) begin
        idleLock <= False;
      end
      Bool canIssueMem = !memExcp.valid && !memRedirectPending;
      ByteMask m = fromMaybe(5'b00000, execPkt.mask);
      let storePkt = selectStoreData(eInst.data, eInst.addr[1:0], m[3:0]);
      Bit#(WordSz) storeByteEn = tpl_1(storePkt);
      Data storeWData = tpl_2(storePkt);
      Bool memUseCache = True;
      Bool setRedirectPending = memExcp.valid || execPkt.isNeedFlush ||
        eInst.iType == Ertn;

      memPaddr = eInst.addr;
      if (canIssueMem) begin
        Bool dCacheCacop = isCacop && cacopNeedsDCache;
        if (isLoad || isStore || isSc || dCacheCacop || cacopNeedsICache) begin
          MmuAccessType accessType = (isStore || isSc) ? MmuStore : MmuLoad;
          Data crmd = csrf.crmd;
          MmuTranslateType transType = getMmuTranslateType(crmd);
          MmuResult dTrans = MmuResult{
            pa: eInst.addr, mat: getDataMatType(crmd), fromDmw: False,
            fromTlb: False, excValid: False, ecode: 0, esubcode: 0,
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
            memExcp = mkExcp(dTrans.ecode, dTrans.esubcode, dTrans.badv);
            setRedirectPending = True;
            canIssueMem = False;
          end
        end
      end

      if (setRedirectPending) begin
        memRedirectPending <= True;
      end

      Bool needsDCache = canIssueMem &&
        (isLoad || isStore || isSc || isBarrier || cacopNeedsDCache);

      if (needsDCache) begin
        Bit#(WordSz) byteEn = 4'b0000;
        Data wData = 0;
        MemOp memOp = Ld;
        if (isLoad) begin
          memOp = (eInst.iType == Ll) ? Ll : Ld;
        end else if (isStore || isSc) begin
          byteEn = storeByteEn;
          wData = storeWData;
          memOp = isSc ? Sc : St;
        end else if (isBarrier) begin
          memOp = Barrier;
        end else if (cacopNeedsDCache) begin
          memOp = Cacop;
        end

        MemReq cacheReq = MemReq {
          op: memOp,
          addr: memInst.addr,
          paddr: memPaddr,
          useCache: (memOp == Cacop || memOp == Barrier) ? True : memUseCache,
          data: wData,
          byteEn: byteEn,
          cacheOp: isCacop ? cacheOp : 5'b0
        };
        if (memOp == Cacop) begin
          dCache.cacop(cacheReq);
        end else begin
          dCache.req(cacheReq);
        end
        nextOp = M2OpDCache;
      end else if (canIssueMem && cacopNeedsICache) begin
        iCache.cacop(cacheOp, memPaddr, eInst.data);
        nextOp = M2OpICache;
      end else if (canIssueMem && isTlbOp) begin
        TlbOp op = TlbOpSearch;
        Data tlbReqAsid = (eInst.iType == Invtlb) ? eInst.data : csrf.tlbWriteAsid;
        if (eInst.iType == Tlbrd) op = TlbOpRead;
        else if (eInst.iType == Tlbwr) op = TlbOpWrite;
        else if (eInst.iType == Tlbfill) op = TlbOpFill;
        else if (eInst.iType == Invtlb) op = TlbOpInv;
        tlb.req(TlbReq{
          op: op,
          tlbidx: (eInst.iType == Tlbrd) ? zeroExtend(csrf.tlbReadIndex) : csrf.tlbWriteIdx,
          invOp: truncate(fromMaybe(0, eInst.imm)),
          ehi: csrf.tlbWriteEhi,
          elo0: csrf.tlbWriteElo0,
          elo1: csrf.tlbWriteElo1,
          asid: tlbReqAsid,
          va: eInst.addr
        });
        nextOp = M2OpTlb;
      end

    end

    Maybe#(Data) mem1Result = tagged Invalid;
    if (nextInst matches tagged Valid .mem1Inst) begin
      Bool mem1ResultReady = (nextOp == M2OpNone);
      if (mem1ResultReady && isValid(mem1Inst.dst)) begin
        mem1Result = tagged Valid mem1Inst.data;
      end
    end
    regSb.updateMem1(execPkt.sbTag, mem1Result);

    e2mFifo.deq();
    m1m2Fifo.enq(M1toM2{
      pc: execPkt.pc,
`ifdef CONFIG_DIFFTEST
      inst: execPkt.inst,
      csrSnapshot: csrf.diffSnapshot,
`else
`ifdef CONFIG_WB_DEBUG_INST
      inst: execPkt.inst,
`endif
`endif
      excp: memExcp,
      mask: execPkt.mask,
      isNeedFlush: execPkt.isNeedFlush,
      sbTag: execPkt.sbTag,
      eInst: nextInst,
      m2Op: nextOp,
      memPaddr: memPaddr
    });
    endaction
  endfunction

  rule doMemoryStage1NoDataTlb (e2mFifo.notEmpty &&
      !e2mFifo.first.dataTlbLookupPending);
    doMemoryStage1Body(noTlbLookup);
  endrule

  rule doMemoryStage1WithDataTlb (e2mFifo.notEmpty &&
      e2mFifo.first.dataTlbLookupPending);
    let tlbRes <- tlb.dataLookupResp;
    doMemoryStage1Body(tlbRes);
  endrule

  function Action doMemoryStage2Body(Maybe#(DCacheResp) dCacheResp,
      Maybe#(Bool) iCacheResp, Maybe#(TlbReadResult) tlbResp);
    action
    let memPkt = m1m2Fifo.first();
    Maybe#(ExecInst) nextInst = memPkt.eInst;
    Maybe#(TlbReadResult) tlbResult = tagged Invalid;
    ExcpInfo memExcp = memPkt.excp;

    if (memPkt.m2Op == M2OpDCache &&&
        memPkt.eInst matches tagged Valid .mInst &&&
        dCacheResp matches tagged Valid .d) begin
      ExecInst doneInst = mInst;
      Bool isLoad = (doneInst.iType == Ld || doneInst.iType == Ll);
      Bool isStore = (doneInst.iType == St);
      Bool isSc = (doneInst.iType == Sc);
      ByteMask m = fromMaybe(5'b00000, memPkt.mask);
      if (isLoad) begin
        if (doneInst.iType == Ld) begin
          doneInst.data = selectLoadData(d.data, doneInst.addr[1:0],
            m[3:0], m[4] == 1'b1);
        end else begin
          doneInst.data = d.data;
        end
      end
      if (isSc) begin
        doneInst.data = d.data;
      end
      nextInst = tagged Valid doneInst;
    end else if (memPkt.m2Op == M2OpTlb &&&
        memPkt.eInst matches tagged Valid .mInst &&&
        tlbResp matches tagged Valid .res) begin
      tlbResult = tagged Valid res;
      if (!memExcp.valid) begin
        if (mInst.iType == Tlbsrch) begin
          Data srchResult = 0;
          if (res.ne) srchResult[`CSR_TLBIDX_NE] = 1'b1;
          else srchResult[`CSR_TLBIDX_INDEX] = res.ehi[`CSR_TLBIDX_INDEX];
          csrf.applyTlbsrchResult(srchResult);
        end else if (mInst.iType == Tlbrd) begin
          csrf.applyTlbrdResult(res.ne, res.ps, res.ehi, res.elo0,
            res.elo1, res.asid);
        end else if (mInst.iType == Tlbwr || mInst.iType == Tlbfill) begin
          csrf.commitTlbOp;
        end
      end
    end else if (memPkt.m2Op == M2OpICache &&&
        iCacheResp matches tagged Valid .done) begin
      noAction;
    end

`ifdef CONFIG_DIFFTEST
    Maybe#(DiffMemOp) diffMemInfo = tagged Invalid;
    if (memPkt.m2Op == M2OpDCache &&&
        memPkt.eInst matches tagged Valid .origInst &&&
        nextInst matches tagged Valid .dInst) begin
      Bool isLoad = (dInst.iType == Ld || dInst.iType == Ll);
      Bool isStore = (dInst.iType == St);
      Bool isSc = (dInst.iType == Sc);
      ByteMask m = fromMaybe(5'b00000, memPkt.mask);
      let storePkt = selectStoreData(origInst.data, origInst.addr[1:0], m[3:0]);
      if (!memExcp.valid && (isLoad || isStore || isSc)) begin
        diffMemInfo = tagged Valid DiffMemOp{
          isLoad: isLoad,
          isStore: isStore || isSc,
          isSc: isSc,
          paddr: memPkt.memPaddr,
          vaddr: dInst.addr,
          storeData: tpl_2(storePkt)
        };
      end
    end
`endif

    Maybe#(Data) mem2Result = tagged Invalid;
    if (nextInst matches tagged Valid .mem2Inst &&& isValid(mem2Inst.dst)) begin
      mem2Result = tagged Valid mem2Inst.data;
    end
    regSb.updateMem2(memPkt.sbTag, mem2Result);

    m1m2Fifo.deq();
    m2wFifo.enq(M2W{
      pc: memPkt.pc,
`ifdef CONFIG_DIFFTEST
      inst: memPkt.inst,
      csrSnapshot: memPkt.csrSnapshot,
`else
`ifdef CONFIG_WB_DEBUG_INST
      inst: memPkt.inst,
`endif
`endif
      excp: memExcp,
      memPaddr: memPkt.memPaddr,
      isNeedFlush: memPkt.isNeedFlush,
      sbTag: memPkt.sbTag,
      mInst: nextInst,
      tlbResult: tlbResult
`ifdef CONFIG_DIFFTEST
      , diffMem: diffMemInfo
`endif
    });
    endaction
  endfunction

  rule doMemoryStage2NoResp (m1m2Fifo.notEmpty &&
      m1m2Fifo.first.m2Op == M2OpNone);
    doMemoryStage2Body(tagged Invalid, tagged Invalid, tagged Invalid);
  endrule

  rule doMemoryStage2DCache (m1m2Fifo.notEmpty &&
      m1m2Fifo.first.m2Op == M2OpDCache);
    let d <- dCache.resp();
    doMemoryStage2Body(tagged Valid d, tagged Invalid, tagged Invalid);
  endrule

  rule doMemoryStage2ICache (m1m2Fifo.notEmpty &&
      m1m2Fifo.first.m2Op == M2OpICache);
    let done <- iCache.cacopResp();
    doMemoryStage2Body(tagged Invalid, tagged Valid done, tagged Invalid);
  endrule

  rule doMemoryStage2Tlb (m1m2Fifo.notEmpty &&
      m1m2Fifo.first.m2Op == M2OpTlb);
    let res <- tlb.resp();
    doMemoryStage2Body(tagged Invalid, tagged Invalid, tagged Valid res);
  endrule

  // ============================================================
  // Stage 7: WB — Writeback to RF/CSR, Exception retirement, Pipeline flush
  // ============================================================
`ifdef CONFIG_WB_DEBUG
  rule driveVsimDebugWb (m2wFifo.notEmpty);
    let memPkt = m2wFifo.first;

    debugWsValidWire <= True;
    debugWbPcWire <= memPkt.pc;
`ifdef CONFIG_WB_DEBUG_INST
    debugWbInstWire <= memPkt.inst;
`endif
    if (memPkt.mInst matches tagged Valid .mInst) begin
      debugWbRfWdataWire <= mInst.data;
      if (mInst.dst matches tagged Valid .dst) begin
        debugWbRfWnumWire <= dst;
        if (!memPkt.excp.valid && dst != 0) begin
          debugWbRfWenWire <= 4'hf;
        end
      end
    end
  endrule
`endif

`ifdef CONFIG_WB_DEBUG
  rule doWriteback (!debugBreakPoint);
`else
  rule doWriteback;
`endif
    let memPkt = m2wFifo.first();
    Bool wbRetire = False;
    Bool wbFlush = False;
    Bool clearDCacheLlOnFlush = False;

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
        Bool wbIsCsrWrite = (mInst.iType == Csrw || mInst.iType == Csrxchg);
`ifdef CONFIG_DIFFTEST
        let currDiffCsrState = memPkt.csrSnapshot;
`endif
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
            wen = (fromMaybe(0, mInst.dst) != 0);
          end
          if (mInst.iType == Ertn) begin
            Bool clearLl = !csrf.llbctlKloValue;
            Addr era <- csrf.returnFromException;
            if (clearLl) begin
              clearDCacheLlOnFlush = True;
            end
            ertnTarget = era;
            pcReg[2] <= era;
            wbFlush = True;
          end else if (mInst.iType == Idle) begin
            pcReg[2] <= memPkt.pc + 4;
            idleLock <= True;
            wbFlush = True;
          end else if (mInst.iType == Tlbfill) begin
            if (memPkt.tlbResult matches tagged Valid .tlbFillRes) begin
              wbTlbfillIndex = truncate(tlbFillRes.ehi[`CSR_TLBIDX_INDEX]);
            end
          end else if (mInst.iType == Ibar) begin
            iCache.invalidate;
          end else if (mInst.iType == Ll) begin
            csrf.setLlbit(True);
          end else if (mInst.iType == Sc) begin
            csrf.setLlbit(False);
          end else begin
            if (wbIsCsrWrite &&& mInst.csr matches tagged Valid .csrIdx &&&
                csrIdx == `CSR_LLBCTL && mInst.addr[1] == 1'b1) begin
              clearDCacheLlOnFlush = True;
            end
            csrf.wr(wbIsCsrWrite ? mInst.csr : Invalid, wbIsCsrWrite ? mInst.addr : mInst.data);
          end

          if (!wbFlush && memPkt.isNeedFlush) begin
            pcReg[2] <= memPkt.pc + 4;
            wbFlush = True;
          end
        end

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

        DiffStoreEvent storeEvent = !wb_has_excp ?
          diffStoreEventOf(memPkt.diffMem, mInst.iType, mInst.mask, mInst.data) :
          DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0};
        DiffLoadEvent loadEvent = !wb_has_excp ?
          diffLoadEventOf(memPkt.diffMem, mInst.iType, mInst.mask) :
          DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0};

        let diffRegsState = rf.diffSnapshotAfterWrite(diffDst, mInst.data);

        DiffArchCsrState diffCsrState = diffSnapshotAfterWriteFromState(
          currDiffCsrState,
          diffCsrIdx,
          diffCsrVal,
          wb_has_excp,
          wb_ecode,
          wb_esubcode,
          memPkt.pc,
          wbExcp.badv,
          diffCommitErtn
          );
        if (mInst.iType == Tlbrd) begin
          if (memPkt.tlbResult matches tagged Valid .tlbRead) begin
            diffCsrState = diffSnapshotAfterTlbrdFromState(currDiffCsrState,
              tlbRead.ne, tlbRead.ps, tlbRead.ehi, tlbRead.elo0,
              tlbRead.elo1, tlbRead.asid);
          end
        end
        if (!wb_has_excp && (mInst.iType == Ll || mInst.iType == Sc)) begin
          Data diffLlbctl = diffCsrState.llbctl;
          diffLlbctl[0] = pack(mInst.iType == Ll);
          diffCsrState.llbctl = diffLlbctl;
        end

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
          interrupt: mkInterruptNo(diffCsrState.estat),
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
        `ifdef CONFIG_TRACE_PERFORMANCE
          if (!wb_has_excp) begin
            inst_count();
          end
        `endif
        if (!wbFlush) begin
          wbRetire = True;
        end
      end
    end else begin
      wbRetire = True;
    end

    if (wbFlush) begin
      iCache.squash();
      tlb.squashReq();
      tlb.squashFetchLookup();
      tlb.squashDataLookup();
      dCache.squash(clearDCacheLlOnFlush);
      memRedirectPending <= False;
      if2WaitRefill <= False;
      f1f2Fifo.clear();
      f2dFifo.clear();
      d2rFifo.clear();
      r2eFifo.clear();
      e2mFifo.clear();
      m1m2Fifo.clear();
      m2wFifo.clear();
      regSb.clear();
      csrSb.clear();
      mulInFlight <= False;
      divInFlight <= False;
    end else if (wbRetire) begin
      if (isValid(memPkt.mInst)) begin
        let retiredType = fromMaybe(?, memPkt.mInst).iType;
      end
      m2wFifo.deq();
      regSb.remove();
      csrSb.deq();
    end
  endrule

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

  method Data rfRdata = debugInforFlag ? rf.rdDebug(debugRegNum) : 0;

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
