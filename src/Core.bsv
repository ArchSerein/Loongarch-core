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

  Ehr#(4, Bool)    exeEpoch <- mkEhr(False);

  Fifo#(2, F2D)           f2dFifo <- mkCFFifo;
  Fifo#(2, D2R)           d2rFifo <- mkCFFifo;
  Fifo#(2, R2E)           r2eFifo <- mkCFFifo;
  Fifo#(2, E2M)           e2mFifo <- mkCFFifo;
  Fifo#(2, M2W)           m2wFifo <- mkCFFifo;
`ifdef CONFIG_DIFFTEST
  Fifo#(2, PendingDiffTrace) pendingDiffFifo <- mkPipelineFifo;
  Fifo#(2, DiffTrace) diffTraceFifo <- mkCFFifo;
`endif

  rule doFetch (csrf.started);
    Addr predPc = btb.predPc(pcReg[0]);
    Bool bhtPred = bht.predict(pcReg[0]);
    Addr dnpc = bhtPred ? predPc : pcReg[0] + 4;
    ExcpInfo fExcp = mkNoExcp;
    if (pcReg[0][1:0] != 2'b00) begin
      fExcp = mkExcp(`ECODE_ADE, `ESUBCODE_ADEF, pcReg[0]);
    end

    iCache.req(pcReg[0]);
    pcReg[0] <= dnpc;

    f2dFifo.enq(F2D{pc: pcReg[0], predPc: dnpc, fEpoch: exeEpoch[0], excp: fExcp});
  endrule

  rule doDecode (csrf.started);
    let inst <- iCache.resp();
    let fetchPkt = f2dFifo.first();
    f2dFifo.deq();

    if (fetchPkt.fEpoch == exeEpoch[1]) begin
      DecodedInst dInst = decode(inst);
      ExcpInfo dExcp = fetchPkt.excp;
      // 检测异常(ine, syscall, break)
      if (!dExcp.valid) begin
        if (dInst.iType == Unsupported) dExcp = mkExcp(`ECODE_INE, `ESUBCODE_NONE, fetchPkt.pc);
        else if (dInst.iType == Syscall) dExcp = mkExcp(`ECODE_SYS, `ESUBCODE_NONE, fetchPkt.pc);
        else if (dInst.iType == Break) dExcp = mkExcp(`ECODE_BRK, `ESUBCODE_NONE, fetchPkt.pc);
      end

`ifdef CONFIG_DIFFTEST
      d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: fetchPkt.predPc, dEpoch: fetchPkt.fEpoch,
        dInst: dInst, inst: inst, excp: dExcp});
`else
      d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: fetchPkt.predPc, dEpoch: fetchPkt.fEpoch,
        dInst: dInst, excp: dExcp});
`endif
    end
  endrule

  rule doRrf (csrf.started);
    let decodePkt = d2rFifo.first();

    if (decodePkt.dEpoch != exeEpoch[1]) begin
      // Epoch mismatch: discard stale instruction
      d2rFifo.deq();
    end else begin
      let rInst = decodePkt.dInst;
      if (!sb.search1(rInst.src1) && !sb.search2(rInst.src2)) begin
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
        sb.insert(rInst.dst);
        d2rFifo.deq();
      end
    end
  endrule

  rule doExec (csrf.started);
    let rrfPkt = r2eFifo.first();

    if (rrfPkt.rEpoch != exeEpoch[2]) begin
      // Epoch mismatch: discard stale instruction
      r2eFifo.deq();
      sb.remove();
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

        if (eInst.iType == Ertn) begin
          Addr era <- csrf.returnFromException;
          eInst.mispredict = True;
          eInst.addr = era;
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
      Bit#(WordSz) byteEn = tpl_1(storePkt);
      Data wData = tpl_2(storePkt);

      case (eInst.iType)
        Ld: begin
          dCache.req(MemReq { op: Ld, addr: eInst.addr, data: ?, byteEn: byteEn });
`ifdef CONFIG_MTRACE
          $fwrite(stdout, "[MTRACE] LD pc:%x addr:%x be:%x\n", execPkt.pc, eInst.addr, byteEn);
`endif
        end
        St: begin
          dCache.req(MemReq { op: St, addr: eInst.addr, data: wData, byteEn: byteEn });
`ifdef CONFIG_MTRACE
          $fwrite(stdout, "[MTRACE] ST pc:%x addr:%x be:%x data:%x raw:%x\n", execPkt.pc, eInst.addr, byteEn, wData, eInst.data);
`endif
        end
        Ll: begin
          dCache.req(MemReq { op: Lr, addr: eInst.addr, data: ?, byteEn: byteEn });
`ifdef CONFIG_MTRACE
          $fwrite(stdout, "[MTRACE] LL pc:%x addr:%x be:%x\n", execPkt.pc, eInst.addr, byteEn);
`endif
        end
        Sc: begin
          dCache.req(MemReq { op: Sc, addr: eInst.addr, data: wData, byteEn: byteEn });
`ifdef CONFIG_MTRACE
          $fwrite(stdout, "[MTRACE] SC pc:%x addr:%x be:%x data:%x raw:%x\n", execPkt.pc, eInst.addr, byteEn, wData, eInst.data);
`endif
        end
        Fence: begin
          dCache.req(MemReq { op: Fence, addr: ?, data: ?, byteEn: byteEn });
`ifdef CONFIG_MTRACE
          $fwrite(stdout, "[MTRACE] FENCE pc:%x\n", execPkt.pc);
`endif
        end
        default: noAction;
      endcase

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
    m2wFifo.deq();

    if (isValid(memPkt.mInst)) begin
      let mInst = fromMaybe(?, memPkt.mInst);
      Data rData = mInst.data;
      if (mInst.iType == Ld || mInst.iType == Ll || mInst.iType == Sc) begin
        rData <- dCache.resp();
        if (mInst.iType == Ld) begin
          ByteMask m = fromMaybe(5'b00000, mInst.mask);
          rData = selectLoadData(rData, mInst.addr[1:0], m[3:0], m[4] == 1'b1);
        end
        mInst.data = rData;
      end

      Bool has_int = csrf.hasInterrupt;
      ExcpInfo wbExcp = memPkt.excp;
      Bool wb_has_excp = has_int || wbExcp.valid;
      Bit#(6) wb_ecode = has_int ? `ECODE_INT : wbExcp.ecode;
      Bit#(9) wb_esubcode = has_int ? 0 : wbExcp.esubcode;
      Data interruptBits = has_int ? (csrf.rd(`CSR_ESTAT) & csrf.rd(`CSR_ECFG) & 32'h00001fff) : 0;

      Bool wen = False;
      if (wb_has_excp) begin
        Addr exEntry <- csrf.raiseException(wb_ecode, wb_esubcode, memPkt.pc);
        exeEpoch[3] <= !exeEpoch[3];
        pcReg[3] <= exEntry;
      end else begin
        if (isValid(mInst.dst)) begin
          rf.wr(fromMaybe(?, mInst.dst), mInst.data);
          wen = (fromMaybe(0, mInst.dst) != 0);
        end
        Bool isCsrWrite = (mInst.iType == Csrw || mInst.iType == Csrxchg);
        csrf.wr(isCsrWrite ? mInst.csr : Invalid, isCsrWrite ? mInst.addr : mInst.data);
      end

    `ifdef CONFIG_DIFFTEST
      $fwrite(stdout, "commit: pc->%x, inst->%x\n", memPkt.pc, memPkt.inst);
    `endif
    `ifdef CONFIG_DIFFTEST
      Addr commitNextPc = mInst.mispredict ? mInst.addr : (memPkt.pc + 4);
      Bool isMMIO = (mInst.iType == Ld || mInst.iType == St || mInst.iType == Ll || mInst.iType == Sc)
                    && (mInst.addr[31:16] == 16'hbfaf);

      DiffCommit commit = DiffCommit{
        valid: !wb_has_excp,
        pc: memPkt.pc,
        nextPc: commitNextPc,
        inst: memPkt.inst,
        wen: wen,
        wdest: fromMaybe(0, mInst.dst),
        wdata: mInst.data,
        skip: isMMIO
      };

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

      pendingDiffFifo.enq(PendingDiffTrace{
        commit: commit,
        excp: DiffExcpEvent{
          excpValid: wb_has_excp,
          eret: (mInst.iType == Ertn),
          interrupt: interruptBits,
          exception: has_int ? 0 : zeroExtend(wbExcp.ecode),
          exceptionPC: memPkt.pc,
          exceptionInst: memPkt.inst
        },
        store: storeEvent,
        load: loadEvent
      });
`endif
    end
    sb.remove();
  endrule

`ifdef CONFIG_DIFFTEST
  rule emitDiffTrace (csrf.started && pendingDiffFifo.notEmpty);
    let pending = pendingDiffFifo.first;
    pendingDiffFifo.deq;
    diffTraceFifo.enq(DiffTrace{
      commit: pending.commit,
      regs: rf.diffSnapshot,
      csr: csrf.diffSnapshot,
      excp: pending.excp,
      store: pending.store,
      load: pending.load
    });
  endrule
`endif

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
