import Types::*;
import ProcTypes::*;
import MemTypes::*;
import RFile::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import Mmu::*;
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
import StoreBuf::*;
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
`ifdef CONFIG_VSIM
  (* always_ready, always_enabled *)
  method Action debugInput(Bool breakPoint, Bool inforFlag, RIndx regNum);
  (* always_ready *)
  method Bool wsValid;
  (* always_ready *)
  method Data rfRdata;
  (* always_ready *)
  method Addr debug0WbPc;
  (* always_ready *)
  method Bit#(4) debug0WbRfWen;
  (* always_ready *)
  method RIndx debug0WbRfWnum;
  (* always_ready *)
  method Data debug0WbRfWdata;
  (* always_ready *)
  method Instruction debug0WbInst;
`endif
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
  Reg#(Bool)      execHasControl <- mkReg(False);
  Reg#(Bit#(2)) wbFlushDrainCycles <- mkReg(0);

  Fifo#(2, F2D)           f2dFifo <- mkCFFifo;
  Fifo#(2, D2R)           d2rFifo <- mkCFFifo;
  Fifo#(2, R2E)           r2eFifo <- mkCFFifo;
  Fifo#(2, E2M)           e2mFifo <- mkCFFifo;
  Fifo#(2, M2W)           m2wFifo <- mkCFFifo;
`ifdef CONFIG_BSIM
  Fifo#(2, CpuToHostData) toHostFifo <- mkCFFifo;
`endif
  Reg#(Bool)      wbMemReqIssued <- mkReg(False);
  Reg#(Maybe#(Data)) wbPendingTlbsrchResult <- mkReg(tagged Invalid);
`ifdef CONFIG_VSIM
  Wire#(RIndx)       debugRegNum <- mkDWire(0);
  Wire#(Bool)        debugWsValid <- mkDWire(False);
  Wire#(Addr)        debugWbPc <- mkDWire(0);
  Wire#(Bit#(4))     debugWbRfWen <- mkDWire(0);
  Wire#(RIndx)       debugWbRfWnum <- mkDWire(0);
  Wire#(Data)        debugWbRfWdata <- mkDWire(0);
  Wire#(Instruction) debugWbInst <- mkDWire(0);
`endif

  rule doTlbsrchResult (wbMemReqIssued && csrf.tlbsrchRespValid && !isValid(wbPendingTlbsrchResult));
    let res <- csrf.tlbsrchResultVal;
    csrf.wr(tagged Valid `CSR_TLBIDX, res);
    wbPendingTlbsrchResult <= tagged Valid res;
    wbMemReqIssued <= False;
  endrule
  StoreBuf#(StoreBufEntries) storeBuf <- mkStoreBuf;
  Reg#(StoreBufEntry) storeDrainEntry <- mkRegU;
  Fifo#(2, DCacheRespSrc) dCacheRespSrcQ <- mkCFFifo;
  Reg#(Maybe#(DCacheResp)) pendingMemResp <- mkReg(tagged Invalid);

  // Separate rule to drain dCache.resp() without adding its implicit guard
  // (respQ.notEmpty) to doMemory's CAN_FIRE condition
  rule doMemResp (dCacheRespSrcQ.notEmpty && dCacheRespSrcQ.first == PipeMemResp && !isValid(pendingMemResp));
    let d <- dCache.resp();
    dCacheRespSrcQ.deq();
    pendingMemResp <= tagged Valid d;
  endrule
  Reg#(Bool)           lrValidReg <- mkReg(False);
  Reg#(Addr)            lrAddrReg <- mkRegU;
`ifdef CONFIG_DIFFTEST
  Difftest difftest <- mkDifftest;
`endif

  rule doFetch (wbFlushDrainCycles == 0);
    Addr predPc = btb.predPc(pcReg[0]);
    Bool bhtPred = bht.predict(pcReg[0]);
    Addr dnpc = bhtPred ? predPc: pcReg[0] + 4;
    ExcpInfo fExcp = mkNoExcp;
    MmuResult fTrans = csrf.translateFetch(pcReg[0]);
    if (pcReg[0][1:0] != 2'b00) begin
      fExcp = mkExcp(`ECODE_ADE, `ESUBCODE_ADEF, pcReg[0]);
    end else if (fTrans.excValid) begin
      fExcp = mkExcp(fTrans.ecode, fTrans.esubcode, fTrans.badv);
    end

    if (!fExcp.valid) begin
      iCache.req(fTrans.pa);
    end
    pcReg[0] <= dnpc;

    f2dFifo.enq(F2D{pc: pcReg[0], predPc: dnpc, instPaddr: fTrans.pa, excp: fExcp});
  endrule

  rule doDecode (wbFlushDrainCycles == 0);
    let fetchPkt = f2dFifo.first();
    Instruction inst = 0;
    Bool instReady = True;
    if (!fetchPkt.excp.valid) begin
      let iResp <- iCache.resp();
      inst = iResp.inst;
      instReady = (iResp.addr == fetchPkt.instPaddr);
    end

    if (instReady) begin
      f2dFifo.deq();

      DecodedInst dInst = decode(inst);
      ExcpInfo dExcp = fetchPkt.excp;
      // 检测异常(ine, syscall, break)
      if (!dExcp.valid) begin
        if (dInst.iType == Unsupported) dExcp = mkExcp(`ECODE_INE, `ESUBCODE_NONE, fetchPkt.pc);
        else if (dInst.iType == Syscall) begin
          Bit#(9) syscallEsubcode = (inst[14:0] == 15'h11) ? 9'h001 : `ESUBCODE_NONE;
          dExcp = mkExcp(`ECODE_SYS, syscallEsubcode, fetchPkt.pc);
        end
        else if (dInst.iType == Break) dExcp = mkExcp(`ECODE_BRK, `ESUBCODE_NONE, fetchPkt.pc);
      end

    `ifdef CONFIG_DIFFTEST
      d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: fetchPkt.predPc,
        dInst: dInst, inst: inst, excp: dExcp});
    `else
    `ifdef CONFIG_VSIM
      d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: fetchPkt.predPc,
        inst: inst, dInst: dInst, excp: dExcp});
    `else
      d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: fetchPkt.predPc,
        dInst: dInst, excp: dExcp});
    `endif
    `endif
    end
  endrule

  rule doRrf;
    let decodePkt = d2rFifo.first();

    let rInst = decodePkt.dInst;
    Bool isCsrWrite =(rInst.iType == Csrw || rInst.iType == Csrxchg || rInst.iType == Tlbsrch);
    Maybe#(CsrIndx) targetCsr =(rInst.iType == Tlbsrch) ? tagged Valid`CSR_TLBIDX: rInst.csr;
    Bool isTlbSerial =(rInst.iType == Tlbsrch || rInst.iType == Tlbrd ||
    rInst.iType == Tlbwr || rInst.iType == Tlbfill || rInst.iType == Invtlb);
    Bool csrConflict = isValid(targetCsr) && csrSb.search(targetCsr);
    Bool isBarrier = coreIsBarrier(rInst.iType) || rInst.iType == Cacop;
    Bool noOlderInFlight = !r2eFifo.notEmpty && !e2mFifo.notEmpty && !m2wFifo.notEmpty;
    if (!sb.search1(rInst.src1) && !sb.search2(rInst.src2) &&
    !csrConflict &&
    (!isTlbSerial || noOlderInFlight) && !execHasControl) begin
      Data rVal1 = rf.rd1(fromMaybe(?, rInst.src1));
      Data rVal2 = rf.rd2(fromMaybe(?, rInst.src2));
      Data csrVal = csrf.rd(fromMaybe(?, rInst.csr));

      `ifdef CONFIG_DIFFTEST
      r2eFifo.enq(R2E{pc: decodePkt.pc, predPc: decodePkt.predPc,
        inst: decodePkt.inst, rVal1: rVal1,
        rVal2: rVal2, csrVal: csrVal,
        rInst: rInst, excp: decodePkt.excp});
      `else
      `ifdef CONFIG_VSIM
      r2eFifo.enq(R2E{pc: decodePkt.pc, predPc: decodePkt.predPc,
        inst: decodePkt.inst, rVal1: rVal1,
        rVal2: rVal2, csrVal: csrVal,
        rInst: rInst, excp: decodePkt.excp});
      `else
      r2eFifo.enq(R2E{pc: decodePkt.pc, predPc: decodePkt.predPc,
        rVal1: rVal1,
        rVal2: rVal2, csrVal: csrVal,
        rInst: rInst, excp: decodePkt.excp});
      `endif
      `endif
      csrSb.enq(isCsrWrite ? targetCsr: tagged Invalid);
      sb.insert(rInst.dst);
      d2rFifo.deq();
      if (coreIsBranchType(rInst.iType)) begin
        execHasControl <= True;
      end
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

    if (doNormalExec) begin
      ExecInst eInst = exec(rrfPkt.rInst, rrfPkt.rVal1, rrfPkt.rVal2, rrfPkt.pc,
      rrfPkt.predPc, rrfPkt.csrVal);
      ExcpInfo eExcp = rrfPkt.excp;
      Bool memRespNeeded = False;
      Addr memPaddr = eInst.addr;
      StoreForwardResult storeForward = StoreForwardResult{data: 0, byteEn: 0};
`ifdef CONFIG_DIFFTEST
        Maybe#(DiffMemOp) diffMem = tagged Invalid;
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
        // if branch miss
        // redirect pc and clear fifo between stages
        pcReg[2] <= eInst.addr;
        iCache.squash();
        f2dFifo.clear();
        d2rFifo.clear();
        btb.update(rrfPkt.pc, eInst.addr);
      end
        bht.update(rrfPkt.pc, eInst.brTaken);

      ByteMask m = fromMaybe(5'b00000, rrfPkt.rInst.mask);
      let storePkt = selectStoreData(eInst.data, eInst.addr[1:0], m[3:0]);
      Data wData = tpl_2(storePkt);
      Bool canFinishExec = True;
      Bool noOlderPipeInst = !e2mFifo.notEmpty && !m2wFifo.notEmpty;
      Bool dCacheReqBusy = dCacheRespSrcQ.notEmpty;
      Bool storeBufEmpty = !storeBuf.notEmpty;

      if (!eExcp.valid &&(eInst.iType == Ld || eInst.iType == St ||
      eInst.iType == Ll || eInst.iType == Sc)) begin
        Bit#(4) rawEn = m[3: 0];
        Bool exAle = False;
        if (rawEn == 4'b0011) exAle =(eInst.addr[0] != 1'b0);
      else if (rawEn == 4'b1111) exAle =(eInst.addr[1: 0] != 2'b00);
        if (exAle) eExcp = mkExcp(`ECODE_ALE, `ESUBCODE_NONE, eInst.addr);
      end

      if (!eExcp.valid && (eInst.iType == Ld || eInst.iType == Ll ||
          eInst.iType == St || eInst.iType == Sc)) begin
        MmuAccessType accessType =
          (eInst.iType == St || eInst.iType == Sc) ? MmuStore : MmuLoad;
        MmuResult dTrans = csrf.translateData(eInst.addr, accessType);
        memPaddr = dTrans.pa;
        if (dTrans.excValid) begin
          eExcp = mkExcp(dTrans.ecode, dTrans.esubcode, dTrans.badv);
        end
      end

      begin
        if (eInst.iType == Ll || eInst.iType == Ld) begin
          Bit#(WordSz) loadByteEn = coreLoadByteEn(eInst.addr[1:0], m[3:0]);
          if (noOlderPipeInst) begin
            StoreForwardResult fwd = storeBuf.forward(memPaddr);
            Bool forwardFull = ((loadByteEn & ~fwd.byteEn) == 0);
            if (forwardFull) begin
              if (eInst.iType == Ld) begin
                eInst.data = selectLoadData(fwd.data, eInst.addr[1:0], m[3:0], m[4] == 1'b1);
              end else begin
                eInst.data = fwd.data;
              end
              storeForward = fwd;
              if (eInst.iType == Ll) begin
                lrValidReg <= True;
                lrAddrReg <= memPaddr;
              end
`ifdef CONFIG_DIFFTEST
                diffMem = tagged Valid DiffMemOp{
                  isLoad: True,
                  isStore: False,
                  isSc: False,
                  paddr: memPaddr,
                  vaddr: eInst.addr,
                  storeData: 0
                };
`endif
              end else if (!dCacheReqBusy) begin
                dCache.req(MemReq {
                  op: Ld,
                  addr: memPaddr,
                  data: 0,
                  byteEn: 4'b0000,
                  cacheOp: 5'b0
                });
                dCacheRespSrcQ.enq(PipeMemResp);
                memRespNeeded = True;
                storeForward = fwd;
                if (eInst.iType == Ll) begin
                  lrValidReg <= True;
                  lrAddrReg <= memPaddr;
                end
`ifdef CONFIG_DIFFTEST
                diffMem = tagged Valid DiffMemOp{
                  isLoad: True,
                  isStore: False,
                  isSc: False,
                  paddr: memPaddr,
                  vaddr: eInst.addr,
                  storeData: 0
                };
`endif
              end else begin
                canFinishExec = False;
              end
            end else begin
              canFinishExec = False;
            end
          end else begin
            canFinishExec = False;
          end
        end
        if (eInst.iType == St) begin
            lrValidReg <= False;
`ifdef CONFIG_DIFFTEST
              diffMem = tagged Valid DiffMemOp{
                isLoad: False,
                isStore: True,
                isSc: False,
                paddr: memPaddr,
                vaddr: eInst.addr,
                storeData: wData
              };
`endif
          end
        if (eInst.iType == Sc) begin
            eInst.data = (lrValidReg && lrAddrReg == memPaddr) ? scSucc : scFail;
            lrValidReg <= False;
`ifdef CONFIG_DIFFTEST
              diffMem = tagged Valid DiffMemOp{
                isLoad: False,
                isStore: True,
                isSc: True,
                paddr: memPaddr,
                vaddr: eInst.addr,
                storeData: wData
              };
`endif
          end
        if (coreIsBarrier(eInst.iType)) begin
            if (storeBufEmpty && noOlderPipeInst && !dCacheReqBusy) begin
              dCache.req(MemReq {
                op: Barrier,
                addr: eInst.addr,
                data: 0,
                byteEn: 4'b0000,
                cacheOp: 5'b0
              });
              dCacheRespSrcQ.enq(PipeMemResp);
              memRespNeeded = True;
            end else begin
              canFinishExec = False;
            end
          end
        if (eInst.iType == Cacop) begin
            Bit#(5) cacheOp = fromMaybe(0, eInst.cacheOp);
            if (cacheOp[2:0] != 3'b000) begin
              if (storeBufEmpty && noOlderPipeInst && !dCacheReqBusy) begin
                dCache.req(MemReq {
                  op: Cacop,
                  addr: eInst.addr,
                  data: eInst.data,
                  byteEn: 4'b0000,
                  cacheOp: cacheOp
                });
                dCacheRespSrcQ.enq(PipeMemResp);
                memRespNeeded = True;
              end else begin
                canFinishExec = False;
              end
            end
          end
      Bool execNeedsDCache =
        (eInst.iType == Ld || eInst.iType == Ll || coreIsBarrier(eInst.iType) ||
        (eInst.iType == Cacop && fromMaybe(0, eInst.cacheOp)[2:0] != 3'b000));
      Bool finishExec = canFinishExec || !execNeedsDCache;

      if (finishExec) begin
        r2eFifo.deq();
        if (coreIsBranchType(eInst.iType)) begin
          execHasControl <= False;
        end
`ifdef CONFIG_DIFFTEST
        e2mFifo.enq(E2M{
              pc: rrfPkt.pc,
              inst: rrfPkt.inst,
              diffMem: diffMem,
              excp: eExcp,
              mask: rrfPkt.rInst.mask,
              memRespNeeded: memRespNeeded,
              memPaddr: memPaddr,
              storeForward: storeForward,
              eInst: tagged Valid eInst
            });
`else
            `ifdef CONFIG_VSIM
            e2mFifo.enq(E2M{
              pc: rrfPkt.pc,
              inst: rrfPkt.inst,
              excp: eExcp,
              mask: rrfPkt.rInst.mask,
              memRespNeeded: memRespNeeded,
              memPaddr: memPaddr,
              storeForward: storeForward,
              eInst: tagged Valid eInst
            });
            `else
            e2mFifo.enq(E2M{
              pc: rrfPkt.pc,
              excp: eExcp,
              mask: rrfPkt.rInst.mask,
              memRespNeeded: memRespNeeded,
              memPaddr: memPaddr,
              storeForward: storeForward,
              eInst: tagged Valid eInst
            });
            `endif
`endif
          end
        end
  endrule

  rule doMemory (wbFlushDrainCycles == 0);
    let execPkt = e2mFifo.first();

    if (isValid(execPkt.eInst)) begin
      let eInst = fromMaybe(?, execPkt.eInst);
      Bool memReady = True;

      if (!execPkt.excp.valid && execPkt.memRespNeeded) begin
        if (isValid(pendingMemResp)) begin
          let d = fromMaybe(?, pendingMemResp);
          if (eInst.iType == Ld || eInst.iType == Ll) begin
`ifdef CONFIG_MTRACE
            if (eInst.addr == 32'h000d2aa8) begin
              $fwrite(stdout, "[LDDBG] pc:%x addr:%x data:%x\n",
                execPkt.pc, eInst.addr, d.data);
            end
`endif

            if (eInst.iType == Ld) begin
              ByteMask m = fromMaybe(5'b00000, execPkt.mask);
              Data mergedData = coreApplyByteMask(d.data, execPkt.storeForward.data,
                execPkt.storeForward.byteEn);
              eInst.data = selectLoadData(mergedData, eInst.addr[1:0], m[3:0], m[4] == 1'b1);
            end else begin
              eInst.data = coreApplyByteMask(d.data, execPkt.storeForward.data,
                execPkt.storeForward.byteEn);
            end
          end
        end else begin
          memReady = False;
        end
      end

      if (memReady) begin
        e2mFifo.deq();
        if (execPkt.memRespNeeded) begin
          pendingMemResp <= tagged Invalid;
        end

`ifdef CONFIG_DIFFTEST
      m2wFifo.enq(M2W{
        pc: execPkt.pc,
        inst: execPkt.inst,
        diffMem: execPkt.diffMem,
        excp: execPkt.excp,
        memPaddr: execPkt.memPaddr,
        mInst: tagged Valid eInst
      });
`else
        `ifdef CONFIG_VSIM
        m2wFifo.enq(M2W{
          pc: execPkt.pc,
          inst: execPkt.inst,
          excp: execPkt.excp,
          memPaddr: execPkt.memPaddr,
          mInst: tagged Valid eInst
        });
        `else
        m2wFifo.enq(M2W{
          pc: execPkt.pc,
          excp: execPkt.excp,
          memPaddr: execPkt.memPaddr,
          mInst: tagged Valid eInst
        });
        `endif
`endif
      end
    end else begin
      e2mFifo.deq();
`ifdef CONFIG_DIFFTEST
      m2wFifo.enq(M2W{
        pc: execPkt.pc,
        inst: execPkt.inst,
        diffMem: tagged Invalid,
        excp: execPkt.excp,
        memPaddr: 0,
        mInst: tagged Invalid
      });
      `else
      `ifdef CONFIG_VSIM
      m2wFifo.enq(M2W{
        pc: execPkt.pc,
        inst: execPkt.inst,
        excp: execPkt.excp,
        memPaddr: 0,
        mInst: tagged Invalid
      });
      `else
      m2wFifo.enq(M2W{
        pc: execPkt.pc,
        excp: execPkt.excp,
        memPaddr: 0,
        mInst: tagged Invalid
      });
      `endif
      `endif
    end
  endrule

  rule doStoreDrain (storeBuf.notEmpty && !dCacheRespSrcQ.notEmpty);
    let sbEntry = storeBuf.first;
`ifdef CONFIG_MTRACE
    $fwrite(stdout, "[SBDBG] DRAIN-REQ addr:%x data:%x be:%x\n",
      sbEntry.addr, sbEntry.data, sbEntry.byteEn);
`endif
    dCache.req(MemReq{
      op: St,
      addr: sbEntry.addr,
      data: sbEntry.data,
      byteEn: sbEntry.byteEn,
      cacheOp: 5'b0
    });
    storeDrainEntry <= sbEntry;
    storeBuf.deq();
    dCacheRespSrcQ.enq(StoreDrainResp);
  endrule

  rule doStoreDrainResp (dCacheRespSrcQ.first == StoreDrainResp);
    let _ <- dCache.resp();
    dCacheRespSrcQ.deq();
`ifdef CONFIG_MTRACE
    $fwrite(stdout, "[SBDBG] DRAIN-RSP addr:%x data:%x be:%x\n",
      storeDrainEntry.addr, storeDrainEntry.data, storeDrainEntry.byteEn);
`endif
  endrule

  rule doWritebackFlush (wbFlushDrainCycles != 0);
    wbMemReqIssued <= False;
    wbPendingTlbsrchResult <= tagged Invalid;
    storeBuf.clear();
    lrValidReg <= False;
    iCache.squash();
    dCache.squash();
    dCacheRespSrcQ.clear();
    pendingMemResp <= tagged Invalid;
    f2dFifo.clear();
    d2rFifo.clear();
    r2eFifo.clear();
    e2mFifo.clear();
    m2wFifo.clear();
    csrSb.clear();
    sb.clear();
    mulInFlight <= False;
    divInFlight <= False;
    execHasControl <= False;
    wbFlushDrainCycles <= wbFlushDrainCycles - 1;
`ifdef CONFIG_DIFFTEST
    difftest.clearLive;
`endif
  endrule

  rule doWriteback (wbFlushDrainCycles == 0);
    let memPkt = m2wFifo.first();
    Bool has_int_raw = csrf.hasInterrupt;
    Bool wbRetire = False;
    Bool wbFlush = False;

    if (isValid(memPkt.mInst)) begin
      let mInst = fromMaybe(?, memPkt.mInst);
      Bool wbReady = True;
      Bool isBarrier = coreIsBarrier(mInst.iType);
      Bool isCacop = (mInst.iType == Cacop);
      ByteMask m = fromMaybe(5'b00000, mInst.mask);
      let storePkt = selectStoreData(mInst.data, mInst.addr[1: 0], m[3: 0]);
      Bit#(WordSz) byteEn = tpl_1(storePkt);
      Data wData = tpl_2(storePkt);

      Data wbCrmd = csrf.crmd;
      Data wbPrmd = csrf.prmd;
      Data wbEcfg = csrf.ecfg;
      Data wbEstat = csrf.estat;
      `ifdef CONFIG_MTRACE
      Data wbTcfg = csrf.tcfg;
      Data wbTval = csrf.tval;
      `endif

      Data pendingInterruptBits = wbEstat & wbEcfg & 32'h00001fff;
      Bool timerPending =((pendingInterruptBits & 32'h00000800) != 0);
      Bool softPending =((pendingInterruptBits & 32'h00000003) != 0);
      Bool delayInterrupt = timerPending && !softPending;
      Bool has_int =(!wbMemReqIssued) && has_int_raw &&(!delayInterrupt || hasIntPrev);
      ExcpInfo wbExcp = memPkt.excp;
      Bool wb_finish_on_syscall = False;
`ifdef CONFIG_BSIM
      wb_finish_on_syscall = (!has_int) && wbExcp.valid &&
        (wbExcp.ecode == `ECODE_SYS) && (wbExcp.esubcode == 9'h001);
`endif
      Bool wb_has_excp = has_int || (wbExcp.valid && !wb_finish_on_syscall);
      Bit#(6) wb_ecode = has_int ? `ECODE_INT : wbExcp.ecode;
      Bit#(9) wb_esubcode = has_int ? 0 : wbExcp.esubcode;
      Data interruptBits = has_int ? pendingInterruptBits : 0;
      Data interruptNo = has_int ? ((interruptBits & 32'h00001ffc) >> 2) : 0;
      Addr ertnTarget = 0;
      Bool wbStoreCommit = (!wb_has_excp) &&
        (mInst.iType == St || (mInst.iType == Sc && mInst.data == scSucc));
      Bool wbNeedsFlush = wb_has_excp || ((!wb_has_excp) && mInst.iType == Ertn);
      Bit#(5) wbTlbfillIndex = 0;
      Maybe#(Data) wbTlbsrchResult = wbPendingTlbsrchResult;

`ifdef CONFIG_MTRACE
      Bool inTiWindow = ((memPkt.pc >= 32'h1c072390 && memPkt.pc <= 32'h1c0723b4) ||
        (memPkt.pc >= 32'h1c074f90 && memPkt.pc <= 32'h1c074fb8));
      if (inTiWindow && (mInst.iType == Csrw || mInst.iType == Csrxchg || mInst.iType == Csrr)) begin
        $fwrite(stdout,
        "[CSRDBG] pc:%x type:%x csr:%x wval:%x old:%x hasIntRaw:%0d hasInt:%0d crmd:%x ecfg:%x estat:%x tcfg:%x tval:%x\n",
        memPkt.pc, pack(mInst.iType), fromMaybe(0, mInst.csr), mInst.addr, mInst.data,
        has_int_raw, has_int, wbCrmd, wbEcfg, wbEstat,
        wbTcfg, wbTval);
      end
      if (inTiWindow && has_int) begin
        $fwrite(stdout, "[INTDBG] pc:%x intBits:%x intrNo:%x crmd:%x ecfg:%x estat:%x tcfg:%x tval:%x\n",
        memPkt.pc, interruptBits, interruptNo, wbCrmd, wbEcfg,
        wbEstat, wbTcfg, wbTval);
      end
      if (memPkt.pc == 32'h1c0723ac || memPkt.pc == 32'h1c0725ac ||
      memPkt.pc == 32'h1c0725b0 || memPkt.pc == 32'h1c074fb4) begin
        $fwrite(stdout, "[LOOPDBG] pc:%x hasIntPrev:%0d hasIntRaw:%0d hasInt:%0d crmd:%x ecfg:%x estat:%x tcfg:%x tval:%x\n",
        memPkt.pc, hasIntPrev, has_int_raw, has_int, wbCrmd, wbEcfg,
        wbEstat, wbTcfg, wbTval);
      end
`endif
`ifdef CONFIG_DIFFTEST
      if (memPkt.pc >= 32'h1c074fe0 && memPkt.pc <= 32'h1c075014) begin
        $fwrite(stdout,
        "[WBDBG] pc:%x type:%x csr:%x wval:%x old:%x hasIntPrev:%0d hasIntRaw:%0d hasInt:%0d pending:%x intrNo:%x wbMemReqIssued:%0d wbReady:%0d wbHasExcp:%0d crmd:%x ecfg:%x estat:%x\n",
        memPkt.pc, pack(mInst.iType), fromMaybe(0, mInst.csr), mInst.addr, mInst.data,
        hasIntPrev, has_int_raw, has_int, pendingInterruptBits, interruptNo,
        wbMemReqIssued, wbReady, wb_has_excp, wbCrmd, wbEcfg, wbEstat);
      end
`endif
      if (wbNeedsFlush && storeBuf.notEmpty) begin
        wbReady = False;
        wbMemReqIssued <= False;
      end else if (wbStoreCommit && !storeBuf.notFull) begin
        wbReady = False;
        wbMemReqIssued <= False;
      end else if (!wb_has_excp && mInst.iType == Tlbsrch) begin
        if (isValid(wbPendingTlbsrchResult)) begin
          wbReady = True;
        end else if (!wbMemReqIssued) begin
          csrf.tlbsrch;
          wbMemReqIssued <= True;
          wbReady = False;
        end else begin
          // Result retrieval is handled by doTlbsrchResult rule
          wbReady = False;
        end
      end else begin
        wbMemReqIssued <= False;
      end

      if (wbReady) begin
        Bool wen = False;
        Bool wbIsCsrWrite =(mInst.iType == Csrw || mInst.iType == Csrxchg);
        if (wb_has_excp) begin
          Addr exEntry <- csrf.raiseException(wb_ecode, wb_esubcode, memPkt.pc, wbExcp.badv);
          pcReg[3] <= exEntry;
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
            pcReg[3] <= era;
            wbFlush = True;
          end else if (mInst.iType == Tlbsrch) begin
            noAction;
          end else if (mInst.iType == Invtlb) begin
            csrf.invtlb(truncate(fromMaybe(0, mInst.imm)), mInst.data, mInst.addr);
          end else if (mInst.iType == Tlbwr) begin
            csrf.tlbwr;
          end else if (mInst.iType == Tlbfill) begin
            wbTlbfillIndex <- csrf.tlbfill;
          end else if (mInst.iType == Tlbrd) begin
            csrf.tlbrd;
          end else if (mInst.iType == Ibar) begin
            iCache.invalidate;
          end else if (isCacop && fromMaybe(0, mInst.cacheOp)[2:0] == 3'b000) begin
            iCache.cacop(fromMaybe(0, mInst.cacheOp), mInst.addr, mInst.data);
          end else begin
            csrf.wr(wbIsCsrWrite ? mInst.csr: Invalid, wbIsCsrWrite ? mInst.addr: mInst.data);
          end

          if (wbStoreCommit) begin
            `ifdef CONFIG_MTRACE
            $fwrite(stdout, "[SBDBG] ENQ-ST pc:%x addr:%x data:%x be:%x\n",
            memPkt.pc, mInst.addr, wData, byteEn);
            `endif
            storeBuf.enq(StoreBufEntry{
              addr: memPkt.memPaddr,
              data: wData,
              byteEn: byteEn
            });
          end
        end

`ifdef CONFIG_VSIM
        debugWsValid <= True;
        debugWbPc <= memPkt.pc;
        debugWbRfWen <= wen ? 4'b1111 : 4'b0000;
        debugWbRfWnum <= fromMaybe(0, mInst.dst);
        debugWbRfWdata <= mInst.data;
        debugWbInst <= memPkt.inst;
`endif

`ifdef CONFIG_DIFFTEST
        Bool diffCommitErtn =(!wb_has_excp) &&(mInst.iType == Ertn);
        Addr commitNextPc = diffCommitErtn ? ertnTarget:(mInst.mispredict ? mInst.addr:(memPkt.pc + 4));

        Maybe#(RIndx) diffDst = tagged Invalid;
        Maybe#(CsrIndx) diffCsrIdx = tagged Invalid;
        Data diffCsrVal = mInst.data;
        if (wen && isValid(mInst.dst)) begin
          diffDst = mInst.dst;
        end
        if (!wb_has_excp) begin
          if (mInst.iType == Tlbsrch) begin
            diffCsrIdx = tagged Valid `CSR_TLBIDX;
            diffCsrVal = fromMaybe(?, wbTlbsrchResult);
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
        csrf.diffSnapshotAfterTlbrd:
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
          eret:(mInst.iType == Ertn),
          interrupt: interruptNo,
          exception: has_int ? 0: zeroExtend(wbExcp.ecode),
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

        if (!wbFlush) begin
          wbRetire = True;
          if (mInst.iType == Tlbsrch) begin
            wbPendingTlbsrchResult <= tagged Invalid;
          end
        end
      end
`ifdef CONFIG_DIFFTEST
      else begin
        difftest.clearLive;
      end
`endif
    end else begin
      wbMemReqIssued <= False;
      wbRetire = True;
`ifdef CONFIG_DIFFTEST
      difftest.clearLive;
`endif
    end

    hasIntPrev <= has_int_raw;

    if (wbFlush) begin
      wbPendingTlbsrchResult <= tagged Invalid;
      storeBuf.clear();
      lrValidReg <= False;
      iCache.squash();
      dCache.squash();
      dCacheRespSrcQ.clear();
      pendingMemResp <= tagged Invalid;
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
      execHasControl <= False;
      wbFlushDrainCycles <= 2;
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

`ifdef CONFIG_VSIM
  method Action debugInput(Bool breakPoint, Bool inforFlag, RIndx regNum);
    debugRegNum <= regNum;
  endmethod
  method Bool wsValid = debugWsValid;
  method Data rfRdata = rf.rdDebug(debugRegNum);
  method Addr debug0WbPc = debugWbPc;
  method Bit#(4) debug0WbRfWen = debugWbRfWen;
  method RIndx debug0WbRfWnum = debugWbRfWnum;
  method Data debug0WbRfWdata = debugWbRfWdata;
  method Instruction debug0WbInst = debugWbInst;
`endif

      interface axiMem = axiMux;
endmodule
