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
  Reg#(Bool)       hasIntPrev <- mkReg(False);
  TlbArray                tlb <- mkTlb;
`ifdef CONFIG_DIFFTEST
  Difftest difftest <- mkDifftest;
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
  Reg#(Bool) memExcpPending <- mkReg(False);
  Reg#(Bool)           lrValidReg <- mkReg(False);
  Reg#(Addr)            lrAddrReg <- mkRegU;

  // ============================================================
  // Stage 1: IF1 — PC selection, start I-Cache probe, start I-TLB lookup
  // ============================================================
  rule doIF1;
    Addr pc = pcReg[0];
    Addr btbPc = btb.predPc(pc);
    Bool bhtPred = bht.predict(pc);
    Addr predPc = bhtPred ? btbPc : pc + 4;
    Data crmd = csrf.crmd;
    Data asid = csrf.asid;

    tlb.fetchLookupReq(pc, asid);
    f1f2Fifo.enq(F1toF2{
      pc: pc,
      predPc: predPc,
      crmd: crmd,
      asid: asid,
      dmw0: csrf.dmw0,
      dmw1: csrf.dmw1,
      transType: getMmuTranslateType(crmd),
      probeRes: iCache.probe(pc)
    });
    pcReg[0] <= predPc;
  endrule

  // ============================================================
  // Stage 2: IF2 — I-Cache tag match, instruction selection, I-MMU result
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
      f1f2Fifo.deq();
    end
  endrule

  rule doIF2 (!if2WaitRefill);
    let req = f1f2Fifo.first();
    ICacheProbeResp probeRes = req.probeRes;
    TlbLookupResult tlbRes <- tlb.fetchLookupResp;
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
        iCache.refillReq(fTrans.pa, fetchUseCache);
        if2PendingReq <= req;
        if2MissPaddr <= fTrans.pa;
        if2WaitRefill <= True;
      end
    end
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

  // ============================================================
  // Stage 4: RR — Register File read, CSR read, forwarding logic
  // ============================================================
  rule doRrf;
    let decodePkt = d2rFifo.first();

    let rInst = decodePkt.dInst;

    Bool isCsrWrite = (rInst.iType == Csrw || rInst.iType == Csrxchg || rInst.iType == Tlbsrch);

    Maybe#(CsrIndx) targetCsr = (rInst.iType == Tlbsrch) ? tagged Valid`CSR_TLBIDX : rInst.csr;

    Bool isTlbSerial = (rInst.iType == Tlbrd ||
    rInst.iType == Tlbwr || rInst.iType == Tlbfill || rInst.iType == Invtlb);

    Bool csrConflict = isValid(targetCsr) && csrSb.search(targetCsr);

    Bool isBarrier = coreIsBarrier(rInst.iType) || rInst.iType == Cacop;

    Bool isNeedFlush = isBarrier || isTlbSerial || isCsrWrite;

    ScoreboardSearchResult src1Sb = regSb.search1(rInst.src1);
    ScoreboardSearchResult src2Sb = regSb.search2(rInst.src2);

    Data rVal1 = rf.rd1(fromMaybe(?, rInst.src1));
    Data rVal2 = rf.rd2(fromMaybe(?, rInst.src2));
    Data csrVal = csrf.rd(fromMaybe(?, rInst.csr));

    if (rInst.src1 matches tagged Valid .s1 &&& s1 == 0) begin
      rVal1 = 0;
    end else if (src1Sb.found &&&
        src1Sb.data matches tagged Valid .fwdData1) begin
      rVal1 = fwdData1;
    end

    if (rInst.src2 matches tagged Valid .s2 &&& s2 == 0) begin
      rVal2 = 0;
    end else if (src2Sb.found &&&
        src2Sb.data matches tagged Valid .fwdData2) begin
      rVal2 = fwdData2;
    end

    Bool src1Hazard = src1Sb.found && !isValid(src1Sb.data);
    Bool src2Hazard = src2Sb.found && !isValid(src2Sb.data);
    Bool isNeedStall = csrConflict || src1Hazard || src2Hazard;

    if (!isNeedStall) begin
      ScoreboardTag sbTag = regSb.enqTag;
      r2eFifo.enq(R2E{pc: decodePkt.pc, predPc: decodePkt.predPc,
`ifdef CONFIG_DIFFTEST
        inst: decodePkt.inst,
`endif
        rVal1: rVal1,
        rVal2: rVal2, csrVal: csrVal,
        isNeedFlush: isNeedFlush,
        sbTag: sbTag,
        rInst: rInst, excp: decodePkt.excp});
      regSb.insert(rInst.dst);
      csrSb.enq(isCsrWrite ? targetCsr : tagged Invalid);
      d2rFifo.deq();
    end
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
        pcReg[1] <= eInst.addr;
        iCache.squash();
        tlb.squashFetchLookup();
        f1f2Fifo.clear();
        f2dFifo.clear();
        d2rFifo.clear();
        if2WaitRefill <= False;
        btb.update(rrfPkt.pc, eInst.addr);
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

      Bool dCacheCacop = (eInst.iType == Cacop) && fromMaybe(0, eInst.cacheOp)[2:0] != 3'b000;
      Bool dataTlbLookupPending = (isMemTypeInst || dCacheCacop) &&
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
      Bool cacopNeedsDCache = isCacop && fromMaybe(0, eInst.cacheOp)[2:0] != 3'b000;
      Bool isTlbOp = (eInst.iType == Tlbsrch || eInst.iType == Tlbrd ||
        eInst.iType == Tlbwr || eInst.iType == Tlbfill || eInst.iType == Invtlb);
      Bool memDCacheSideEffect = isStore || isSc || isBarrier ||
        cacopNeedsDCache || isTlbOp;
      Bool memIsCsrWrite = (eInst.iType == Csrw || eInst.iType == Csrxchg);
      Bool memWritesInterruptCsr = False;
      if (memIsCsrWrite &&& eInst.csr matches tagged Valid .csrIdx) begin
        memWritesInterruptCsr = coreIsInterruptControlCsr(csrIdx);
      end

      let intCsrView = coreInterruptCsrView(
        memIsCsrWrite ? eInst.csr : tagged Invalid, eInst.addr, csrf.crmd,
        csrf.ecfg, csrf.estat);
      Data pendingInterruptBits = corePendingInterruptBits(tpl_2(intCsrView),
        tpl_3(intCsrView));
      Bool timerPending = ((pendingInterruptBits & 32'h00000800) != 0);
      Bool softPending = ((pendingInterruptBits & 32'h00000003) != 0);
      Bool delayInterrupt = timerPending && !softPending;
      Bool has_int_raw = coreHasInterrupt(tpl_1(intCsrView), tpl_2(intCsrView),
        tpl_3(intCsrView));
      Bool has_int = !memDCacheSideEffect && !memWritesInterruptCsr &&
        has_int_raw && (!delayInterrupt || hasIntPrev);
      memExcp = has_int ? mkExcp(`ECODE_INT, 0, 0) : execPkt.excp;
      Bool canIssueMem = !memExcp.valid && !memExcpPending;
      ByteMask m = fromMaybe(5'b00000, execPkt.mask);
      let storePkt = selectStoreData(eInst.data, eInst.addr[1:0], m[3:0]);
      Bit#(WordSz) storeByteEn = tpl_1(storePkt);
      Data storeWData = tpl_2(storePkt);
      Bool memUseCache = True;

      hasIntPrev <= has_int_raw;

      if (memExcp.valid) begin
        memExcpPending <= True;
      end

      memPaddr = eInst.addr;
      if (canIssueMem) begin
        Bool dCacheCacop = isCacop && cacopNeedsDCache;
        if (isLoad || isStore || isSc || dCacheCacop) begin
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
            memExcpPending <= True;
            canIssueMem = False;
          end
        end
      end

      if (canIssueMem && isSc) begin
        memInst.data = (lrValidReg && lrAddrReg == memPaddr) ? scSucc : scFail;
        nextInst = tagged Valid memInst;
      end

      Bool scStore = isSc && memInst.data == scSucc;
      Bool needsDCache = canIssueMem &&
        (isLoad || isStore || scStore || isBarrier || cacopNeedsDCache);

      if (needsDCache) begin
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
          addr: memInst.addr,
          paddr: memPaddr,
          useCache: (memOp == Cacop || memOp == Barrier) ? True : memUseCache,
          data: wData,
          byteEn: byteEn,
          cacheOp: isCacop ? fromMaybe(0, eInst.cacheOp) : 5'b0
        });
        nextOp = M2OpDCache;
      end else if (canIssueMem && isTlbOp) begin
        TlbOp op = TlbOpSearch;
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
          asid: csrf.tlbWriteAsid,
          va: eInst.addr
        });
        nextOp = M2OpTlb;
      end

    end

    Maybe#(Data) mem1Result = tagged Invalid;
    if (nextInst matches tagged Valid .mem1Inst) begin
      Bool mem1ResultReady = (nextOp == M2OpNone) || mem1Inst.iType == Sc;
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
      Maybe#(TlbReadResult) tlbResp);
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
          lrValidReg <= True;
          lrAddrReg <= memPkt.memPaddr;
        end
      end
      if (!memExcp.valid && (isStore || isSc)) begin
        lrValidReg <= False;
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
    end

`ifdef CONFIG_DIFFTEST
    Maybe#(DiffMemOp) diffMemInfo = tagged Invalid;
    if (memPkt.m2Op == M2OpDCache &&& nextInst matches tagged Valid .dInst) begin
      Bool isLoad = (dInst.iType == Ld || dInst.iType == Ll);
      Bool isStore = (dInst.iType == St);
      Bool isSc = (dInst.iType == Sc);
      ByteMask m = fromMaybe(5'b00000, memPkt.mask);
      let storePkt = selectStoreData(dInst.data, dInst.addr[1:0], m[3:0]);
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
    doMemoryStage2Body(tagged Invalid, tagged Invalid);
  endrule

  rule doMemoryStage2DCache (m1m2Fifo.notEmpty &&
      m1m2Fifo.first.m2Op == M2OpDCache);
    let d <- dCache.resp();
    doMemoryStage2Body(tagged Valid d, tagged Invalid);
  endrule

  rule doMemoryStage2Tlb (m1m2Fifo.notEmpty &&
      m1m2Fifo.first.m2Op == M2OpTlb);
    let res <- tlb.resp();
    doMemoryStage2Body(tagged Invalid, tagged Valid res);
  endrule

  // ============================================================
  // Stage 7: WB — Writeback to RF/CSR, Exception retirement, Pipeline flush
  // ============================================================
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
            Addr era <- csrf.returnFromException;
            ertnTarget = era;
            pcReg[2] <= era;
            wbFlush = True;
          end else if (mInst.iType == Tlbfill) begin
            if (memPkt.tlbResult matches tagged Valid .tlbFillRes) begin
              wbTlbfillIndex = truncate(tlbFillRes.ehi[`CSR_TLBIDX_INDEX]);
            end
          end else if (mInst.iType == Ibar) begin
            iCache.invalidate;
          end else if (isCacop && fromMaybe(0, mInst.cacheOp)[2:0] == 3'b000) begin
            iCache.cacop(fromMaybe(0, mInst.cacheOp), mInst.addr, mInst.data);
          end else begin
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
      lrValidReg <= False;
      iCache.squash();
      tlb.squashFetchLookup();
      tlb.squashDataLookup();
      dCache.squash();
      memExcpPending <= False;
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

  interface axiMem = axiMux;
endmodule
