import Types::*;
import ProcTypes::*;
import MemTypes::*;
import RFile::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import Fifo::*;
import Ehr::*;
import Btb::*;
import Scoreboard::*;
import SFifo::*;
import Bht::*;
import ICache::*;
import DCache::*;
import Mul::*;
import Div::*;
import AxiTypes::*;
import AxiMem::*;
`include "Autoconf.bsv"
`include "CsrAddr.bsv"
`include "CoreTypes.bsv"
`include "CoreFunc.bsv"

interface Core;
  method ActionValue#(CpuToHostData) cpuToHost;
  method Bool cpuToHostValid;
`ifdef CONFIG_DIFFTEST
  method ActionValue#(DiffTrace) diffTrace;
  method Bool diffTraceValid;
`endif
  method Action hostToCpu(Addr startpc);
  interface AxiMemMaster axiMem;
endinterface

function Bool isTimerRelatedCsr(CsrIndx idx);
  return idx == `CSR_TCFG || idx == `CSR_TVAL || idx == `CSR_TICLR ||
    idx == `CSR_ESTAT;
endfunction

function Bool isFetchAddrLegal(Addr a);
  return (a[31:24] == 8'h1c) || (a[31:24] == 8'h00) ||
    (a[31:24] == 8'h80) || (a[31:24] == 8'ha0);
endfunction

function Bool isCsrConflict(Maybe#(CsrIndx) pendingWrite, Maybe#(CsrIndx) curAccess);
  if (pendingWrite matches tagged Valid .w &&& curAccess matches tagged Valid .a) begin
    Bool sameCsr = (w == a);
    Bool timerSideEffectConflict = isTimerRelatedCsr(w) && isTimerRelatedCsr(a);
    return sameCsr || timerSideEffectConflict;
  end else begin
    return False;
  end
endfunction

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
  SFifo#(6, Maybe#(CsrIndx), Maybe#(CsrIndx)) csrSb <- mkCFSFifo(isCsrConflict);
  Reg#(Bool)       hasIntPrev <- mkReg(False);
  Reg#(Bool)    fenceInFlight <- mkReg(False);
  Reg#(Bool)   fenceFrontStall <- mkReg(False);

  Ehr#(4, Bool)    exeEpoch <- mkEhr(False);

  Fifo#(2, F2D)           f2dFifo <- mkCFFifo;
  Fifo#(2, D2R)           d2rFifo <- mkCFFifo;
  Fifo#(2, R2E)           r2eFifo <- mkCFFifo;
  Fifo#(2, E2M)           e2mFifo <- mkCFFifo;
  Fifo#(2, M2W)           m2wFifo <- mkCFFifo;
  Reg#(Bool)      wbMemReqIssued <- mkReg(False);
`ifdef CONFIG_DIFFTEST
  Fifo#(2, DiffTrace) diffTraceFifo <- mkCFFifo;
`endif

  rule doFetch (csrf.started && !fenceFrontStall);
    Addr predPc = btb.predPc(pcReg[0]);
    Bool bhtPred = bht.predict(pcReg[0]);
    Addr dnpc = bhtPred ? predPc : pcReg[0] + 4;
    ExcpInfo fExcp = mkNoExcp;
    if (pcReg[0][1:0] != 2'b00) begin
      fExcp = mkExcp(`ECODE_ADE, `ESUBCODE_ADEF, pcReg[0]);
    end else if (!isFetchAddrLegal(pcReg[0])) begin
      fExcp = mkExcp(`ECODE_ADE, `ESUBCODE_ADEF, pcReg[0]);
    end

    if (!fExcp.valid) begin
      iCache.req(pcReg[0]);
    end
    pcReg[0] <= dnpc;

    f2dFifo.enq(F2D{pc: pcReg[0], predPc: dnpc, fEpoch: exeEpoch[0], excp: fExcp});
  endrule

  rule doDecode (csrf.started && !fenceFrontStall);
    let fetchPkt = f2dFifo.first();
    f2dFifo.deq();
    Instruction inst = 0;
    if (!fetchPkt.excp.valid) begin
      inst <- iCache.resp();
    end

      if (fetchPkt.fEpoch == exeEpoch[1]) begin
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
      d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: fetchPkt.predPc, dEpoch: fetchPkt.fEpoch,
        dInst: dInst, inst: inst, excp: dExcp});
`else
      d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: fetchPkt.predPc, dEpoch: fetchPkt.fEpoch,
        dInst: dInst, excp: dExcp});
`endif
      if (dInst.iType == Fence) begin
        fenceFrontStall <= True;
      end
    end
  endrule

  rule doRrf (csrf.started);
    let decodePkt = d2rFifo.first();

    if (decodePkt.dEpoch != exeEpoch[1]) begin
      // Epoch mismatch: discard stale instruction
      d2rFifo.deq();
    end else begin
      let rInst = decodePkt.dInst;
      Bool isCsrWrite = (rInst.iType == Csrw || rInst.iType == Csrxchg);
      Bool csrConflict = isValid(rInst.csr) && csrSb.search(rInst.csr);
      Bool isFence = (rInst.iType == Fence);
      if (!sb.search1(rInst.src1) && !sb.search2(rInst.src2) &&
          !csrConflict && !fenceInFlight) begin
        Data    rVal1 = rf.rd1(fromMaybe(?, rInst.src1));
        Data    rVal2 = rf.rd2(fromMaybe(?, rInst.src2));
        Data    csrVal = csrf.rd(fromMaybe(?, rInst.csr));

`ifdef CONFIG_DIFFTEST
        r2eFifo.enq(R2E{pc: decodePkt.pc, predPc: decodePkt.predPc, rEpoch: decodePkt.dEpoch,
          inst: decodePkt.inst, rVal1: rVal1,
          rVal2: rVal2, csrVal: csrVal,
          rInst: rInst, excp: decodePkt.excp});
`else
        r2eFifo.enq(R2E{pc: decodePkt.pc, predPc: decodePkt.predPc, rEpoch: decodePkt.dEpoch,
          rVal1: rVal1,
          rVal2: rVal2, csrVal: csrVal,
          rInst: rInst, excp: decodePkt.excp});
`endif
        csrSb.enq(isCsrWrite ? rInst.csr : tagged Invalid);
        sb.insert(rInst.dst);
        d2rFifo.deq();
        if (isFence) begin
          fenceInFlight <= True;
        end
      end
    end
  endrule

  rule doExec (csrf.started);
    let rrfPkt = r2eFifo.first();

    if (rrfPkt.rEpoch != exeEpoch[2]) begin
      // Epoch mismatch: discard stale instruction
      r2eFifo.deq();
`ifdef CONFIG_DIFFTEST
      e2mFifo.enq(E2M{
        pc: rrfPkt.pc,
        inst: rrfPkt.inst,
        excp: rrfPkt.excp,
        mask: rrfPkt.rInst.mask,
        eInst: tagged Invalid
      });
`else
      e2mFifo.enq(E2M{
        pc: rrfPkt.pc,
        excp: rrfPkt.excp,
        mask: rrfPkt.rInst.mask,
        eInst: tagged Invalid
      });
`endif
    end else begin
      Bool doNormalExec = True;

      if (isValid(rrfPkt.rInst.muldivFunc)) begin
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
        r2eFifo.deq();
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
        end

        if (eInst.mispredict) begin
          exeEpoch[2] <= !exeEpoch[2];
          pcReg[2] <= eInst.addr;
          btb.update(rrfPkt.pc, eInst.addr);
        end
        bht.update(rrfPkt.pc, eInst.brTaken);

        if (!eExcp.valid && (eInst.iType == Ld || eInst.iType == St ||
            eInst.iType == Ll || eInst.iType == Sc)) begin
          ByteMask m = fromMaybe(5'b11111, rrfPkt.rInst.mask);
          Bit#(4) rawEn = m[3:0];
          Bool exAle = False;
          if (rawEn == 4'b0011) exAle = (eInst.addr[0] != 1'b0);
          else if (rawEn == 4'b1111) exAle = (eInst.addr[1:0] != 2'b00);
          if (exAle) eExcp = mkExcp(`ECODE_ALE, `ESUBCODE_NONE, eInst.addr);
        end

`ifdef CONFIG_DIFFTEST
        e2mFifo.enq(E2M{pc: rrfPkt.pc,
          inst: rrfPkt.inst, excp: eExcp,
          mask: rrfPkt.rInst.mask,
          eInst: tagged Valid eInst});
`else
        e2mFifo.enq(E2M{pc: rrfPkt.pc,
          excp: eExcp,
          mask: rrfPkt.rInst.mask,
          eInst: tagged Valid eInst});
`endif
      end
    end
  endrule

  rule doMemory (csrf.started);
    let execPkt = e2mFifo.first();
    e2mFifo.deq();

    if (isValid(execPkt.eInst)) begin
      let eInst = fromMaybe(?, execPkt.eInst);

      ByteMask m = fromMaybe(5'b00000, execPkt.mask);
      let storePkt = selectStoreData(eInst.data, eInst.addr[1:0], m[3:0]);
      Data wData = tpl_2(storePkt);

`ifdef CONFIG_DIFFTEST
      Maybe#(DiffMemOp) diffMem = tagged Invalid;
      if (eInst.iType == Ld || eInst.iType == Ll) begin
        diffMem = tagged Valid DiffMemOp{
          isLoad: True,
          isStore: False,
          isSc: False,
          addr: eInst.addr,
          storeData: 0
        };
      end else if (eInst.iType == St || eInst.iType == Sc) begin
        diffMem = tagged Valid DiffMemOp{
          isLoad: False,
          isStore: True,
          isSc: (eInst.iType == Sc),
          addr: eInst.addr,
          storeData: wData
        };
      end
      m2wFifo.enq(M2W{
        pc: execPkt.pc,
        inst: execPkt.inst,
        diffMem: diffMem,
        excp: execPkt.excp,
        mInst: tagged Valid eInst
      });
`else
      m2wFifo.enq(M2W{
        pc: execPkt.pc,
        excp: execPkt.excp,
        mInst: tagged Valid eInst
      });
`endif
    end else begin
`ifdef CONFIG_DIFFTEST
      m2wFifo.enq(M2W{
        pc: execPkt.pc,
        inst: execPkt.inst,
        diffMem: tagged Invalid,
        excp: execPkt.excp,
        mInst: tagged Invalid
      });
`else
      m2wFifo.enq(M2W{
        pc: execPkt.pc,
        excp: execPkt.excp,
        mInst: tagged Invalid
      });
`endif
    end
  endrule

  rule doWriteback (csrf.started);
    let memPkt = m2wFifo.first();
    Bool has_int_raw = csrf.hasInterrupt;
    Bool wbRetire = False;
    Bool wbFlush = False;

    if (isValid(memPkt.mInst)) begin
      let mInst = fromMaybe(?, memPkt.mInst);
      Data rData = mInst.data;
      Bool wbReady = True;

      ByteMask m = fromMaybe(5'b00000, mInst.mask);
      let storePkt = selectStoreData(mInst.data, mInst.addr[1:0], m[3:0]);
      Bit#(WordSz) byteEn = tpl_1(storePkt);
      Data wData = tpl_2(storePkt);

      Bool isMemOp = (mInst.iType == Ld || mInst.iType == Ll || mInst.iType == St ||
        mInst.iType == Sc || mInst.iType == Fence);
      Bool memNeedResp = (mInst.iType == Ld || mInst.iType == Ll ||
        mInst.iType == Sc || mInst.iType == Fence);

      Data pendingInterruptBits = csrf.rd(`CSR_ESTAT) & csrf.rd(`CSR_ECFG) & 32'h00001fff;
      Bool timerPending = ((pendingInterruptBits & 32'h00000800) != 0);
      Bool softPending = ((pendingInterruptBits & 32'h00000003) != 0);
      Bool delayInterrupt = timerPending && !softPending;
      Bool has_int = (!wbMemReqIssued) && has_int_raw && (!delayInterrupt || hasIntPrev);
      ExcpInfo wbExcp = memPkt.excp;
      Bool wb_finish_on_syscall = (!has_int) && wbExcp.valid &&
        (wbExcp.ecode == `ECODE_SYS) && (wbExcp.esubcode == 9'h001);
      Bool wb_has_excp = has_int || (wbExcp.valid && !wb_finish_on_syscall);
      Bit#(6) wb_ecode = has_int ? `ECODE_INT : wbExcp.ecode;
      Bit#(9) wb_esubcode = has_int ? 0 : wbExcp.esubcode;
      Data interruptBits = has_int ? pendingInterruptBits : 0;
      Data interruptNo = has_int ? ((interruptBits & 32'h00001ffc) >> 2) : 0;
      Bool commitErtn = (!wb_has_excp) && (mInst.iType == Ertn);
      Addr ertnTarget = 0;
      Data ertnNextCrmd = 0;
      if (commitErtn) begin
        Data curCrmd = csrf.rd(`CSR_CRMD);
        Data prmd = csrf.rd(`CSR_PRMD);
        ertnNextCrmd = curCrmd;
        ertnNextCrmd[`CSR_CRMD_PLV] = prmd[`CSR_PRMD_PPLV];
        ertnNextCrmd[`CSR_CRMD_IE] = prmd[`CSR_PRMD_PIE];
      end

`ifdef CONFIG_MTRACE
      Bool inTiWindow = ((memPkt.pc >= 32'h1c072390 && memPkt.pc <= 32'h1c0723b4) ||
        (memPkt.pc >= 32'h1c074f90 && memPkt.pc <= 32'h1c074fb8));
      if (inTiWindow && (mInst.iType == Csrw || mInst.iType == Csrxchg || mInst.iType == Csrr)) begin
        $fwrite(stdout,
          "[CSRDBG] pc:%x type:%x csr:%x wval:%x old:%x hasIntRaw:%0d hasInt:%0d crmd:%x ecfg:%x estat:%x tcfg:%x tval:%x\n",
          memPkt.pc, pack(mInst.iType), fromMaybe(0, mInst.csr), mInst.addr, mInst.data,
          has_int_raw, has_int, csrf.rd(`CSR_CRMD), csrf.rd(`CSR_ECFG), csrf.rd(`CSR_ESTAT),
          csrf.rd(`CSR_TCFG), csrf.rd(`CSR_TVAL));
      end
      if (inTiWindow && has_int) begin
        $fwrite(stdout, "[INTDBG] pc:%x intBits:%x intrNo:%x crmd:%x ecfg:%x estat:%x tcfg:%x tval:%x\n",
          memPkt.pc, interruptBits, interruptNo, csrf.rd(`CSR_CRMD), csrf.rd(`CSR_ECFG),
          csrf.rd(`CSR_ESTAT), csrf.rd(`CSR_TCFG), csrf.rd(`CSR_TVAL));
      end
      if (memPkt.pc == 32'h1c0723ac || memPkt.pc == 32'h1c0725ac ||
          memPkt.pc == 32'h1c0725b0 || memPkt.pc == 32'h1c074fb4) begin
        $fwrite(stdout, "[LOOPDBG] pc:%x hasIntPrev:%0d hasIntRaw:%0d hasInt:%0d crmd:%x ecfg:%x estat:%x tcfg:%x tval:%x\n",
          memPkt.pc, hasIntPrev, has_int_raw, has_int, csrf.rd(`CSR_CRMD), csrf.rd(`CSR_ECFG),
          csrf.rd(`CSR_ESTAT), csrf.rd(`CSR_TCFG), csrf.rd(`CSR_TVAL));
      end
`endif

      if (!wb_has_excp && isMemOp) begin
        if (memNeedResp) begin
          if (!wbMemReqIssued) begin
            MemOp op = (mInst.iType == Ll) ? Lr :
              ((mInst.iType == Sc) ? Sc :
              ((mInst.iType == Fence) ? Fence : Ld));
            dCache.req(MemReq { op: op, addr: mInst.addr, data: wData, byteEn: byteEn });
            wbMemReqIssued <= True;
`ifdef CONFIG_MTRACE
            case (mInst.iType)
              Ld: $fwrite(stdout, "[MTRACE] LD pc:%x addr:%x be:%x\n", memPkt.pc, mInst.addr, byteEn);
              Ll: $fwrite(stdout, "[MTRACE] LL pc:%x addr:%x be:%x\n", memPkt.pc, mInst.addr, byteEn);
              Sc: $fwrite(stdout, "[MTRACE] SC pc:%x addr:%x be:%x data:%x raw:%x\n", memPkt.pc, mInst.addr, byteEn, wData, mInst.data);
              Fence: $fwrite(stdout, "[MTRACE] FENCE pc:%x addr:%x\n", memPkt.pc, mInst.addr);
              default: noAction;
            endcase
`endif
            wbReady = False;
          end else begin
            rData <- dCache.resp();
            wbMemReqIssued <= False;
            if (mInst.iType == Ld) begin
              rData = selectLoadData(rData, mInst.addr[1:0], m[3:0], m[4] == 1'b1);
            end
            mInst.data = rData;
          end
        end else begin
          MemOp op = (mInst.iType == St) ? St : Fence;
          if (mInst.iType == Fence) begin
            iCache.invalidate;
          end
          dCache.req(MemReq { op: op, addr: mInst.addr, data: wData, byteEn: byteEn });
`ifdef CONFIG_MTRACE
          case (mInst.iType)
            St: $fwrite(stdout, "[MTRACE] ST pc:%x addr:%x be:%x data:%x raw:%x\n", memPkt.pc, mInst.addr, byteEn, wData, mInst.data);
            Fence: $fwrite(stdout, "[MTRACE] FENCE pc:%x addr:%x\n", memPkt.pc, mInst.addr);
            default: noAction;
          endcase
`endif
        end
      end else begin
        wbMemReqIssued <= False;
      end

      if (wbReady) begin
        Bool wen = False;
        if (wb_has_excp) begin
          Addr exEntry <- csrf.raiseException(wb_ecode, wb_esubcode, memPkt.pc, wbExcp.badv);
          exeEpoch[3] <= !exeEpoch[3];
          pcReg[3] <= exEntry;
          wbFlush = True;
        end else begin
          if (wb_finish_on_syscall) begin
            csrf.finish;
          end
          if (isValid(mInst.dst)) begin
            rf.wr(fromMaybe(?, mInst.dst), mInst.data);
            wen = (fromMaybe(0, mInst.dst) != 0);
          end
          if (mInst.iType == Ertn) begin
            Addr era <- csrf.returnFromException;
            csrf.wr(Invalid, mInst.data);
            ertnTarget = era;
            exeEpoch[3] <= !exeEpoch[3];
            pcReg[3] <= era;
            wbFlush = True;
          end else begin
            Bool wbIsCsrWrite = (mInst.iType == Csrw || mInst.iType == Csrxchg);
            csrf.wr(wbIsCsrWrite ? mInst.csr : Invalid, wbIsCsrWrite ? mInst.addr : mInst.data);
          end
        end

      `ifdef CONFIG_DIFFTEST
        $fwrite(stdout, "commit: pc->%x, inst->%x\n", memPkt.pc, memPkt.inst);
      `else
        $fwrite(stdout, "commit: pc->%x\n", memPkt.pc);
      `endif
      `ifdef CONFIG_DIFFTEST
        Addr commitNextPc = commitErtn ? ertnTarget : (mInst.mispredict ? mInst.addr : (memPkt.pc + 4));

        Maybe#(RIndx) diffDst = tagged Invalid;
        Maybe#(CsrIndx) diffCsrIdx = tagged Invalid;
        Data diffCsrVal = mInst.data;
        if (wen && isValid(mInst.dst)) begin
          diffDst = mInst.dst;
        end
        if (!wb_has_excp) begin
          if (mInst.iType == Ertn) begin
            diffCsrIdx = tagged Valid `CSR_CRMD;
            diffCsrVal = ertnNextCrmd;
          end else if (mInst.iType == Csrw || mInst.iType == Csrxchg) begin
            diffCsrIdx = mInst.csr;
            diffCsrVal = mInst.addr;
          end
        end

        DiffStoreEvent storeEvent = DiffStoreEvent{
          valid: False,
          paddr: 0,
          vaddr: 0,
          data: 0
        };
        DiffLoadEvent loadEvent = DiffLoadEvent{
          valid: False,
          paddr: 0,
          vaddr: 0
        };

          if (!wb_has_excp) begin
            if (memPkt.diffMem matches tagged Valid .diffMem) begin
              if (diffMem.isStore && (!diffMem.isSc || rData == scSucc)) begin
                storeEvent = DiffStoreEvent{
                  valid: True,
                  paddr: zeroExtend(diffMem.addr),
                  vaddr: zeroExtend(diffMem.addr),
                  data: zeroExtend(diffMem.storeData)
                };
              end
              if (diffMem.isLoad) begin
                loadEvent = DiffLoadEvent{
                  valid: True,
                  paddr: zeroExtend(diffMem.addr),
                  vaddr: zeroExtend(diffMem.addr)
                };
              end
            end
          end
 
        diffTraceFifo.enq(DiffTrace{
          commit: DiffCommit{
            valid: !wb_has_excp,
            pc: memPkt.pc,
            nextPc: commitNextPc,
            inst: memPkt.inst,
            wen: wen,
            wdest: fromMaybe(0, mInst.dst),
            wdata: mInst.data,
            skip: False
          },
          regs: rf.diffSnapshotAfterWrite(diffDst, mInst.data),
          csr: csrf.diffSnapshotAfterWrite(
            diffCsrIdx,
            diffCsrVal,
            wb_has_excp,
            wb_ecode,
            wb_esubcode,
            memPkt.pc,
            wbExcp.badv
          ),
          excp: DiffExcpEvent{
            excpValid: wb_has_excp,
            eret: (mInst.iType == Ertn),
            interrupt: interruptNo,
            exception: has_int ? 0 : zeroExtend(wbExcp.ecode),
            exceptionPC: memPkt.pc,
            exceptionInst: memPkt.inst
          },
          store: storeEvent,
          load: loadEvent
        });
      `endif

        if (!wbFlush) begin
          wbRetire = True;
        end
      end
    end else begin
      wbMemReqIssued <= False;
      wbRetire = True;
    end

    hasIntPrev <= has_int_raw;

    if (wbFlush) begin
      d2rFifo.clear();
      r2eFifo.clear();
      e2mFifo.clear();
      m2wFifo.clear();
      csrSb.clear();
      sb.clear();
      fenceInFlight <= False;
      fenceFrontStall <= False;
    end else if (wbRetire) begin
      if (isValid(memPkt.mInst) && fromMaybe(?, memPkt.mInst).iType == Fence) begin
        fenceInFlight <= False;
        fenceFrontStall <= False;
      end
      m2wFifo.deq();
      csrSb.deq();
      sb.remove();
    end
  endrule

  method ActionValue#(CpuToHostData) cpuToHost = csrf.cpuToHost;
  method Bool cpuToHostValid = csrf.cpuToHostValid;

`ifdef CONFIG_DIFFTEST
  method ActionValue#(DiffTrace) diffTrace if (diffTraceFifo.notEmpty);
    let ret = diffTraceFifo.first;
    diffTraceFifo.deq;
    return ret;
  endmethod
  method Bool diffTraceValid = diffTraceFifo.notEmpty;
`endif

  // TODO: this method will be remove
  method Action hostToCpu(Addr startpc) if (!csrf.started);
    csrf.start;
    pcReg[0] <= startpc;
  endmethod

  interface axiMem = axiMux;
endmodule
