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
import AxiTypes::*;
import AxiMem::*;
`include "Autoconf.bsv"

interface Core;
  method ActionValue#(CpuToHostData) cpuToHost;
  method Bool cpuToHostValid;
  `IFDEF_DIFFTEST(
    method ActionValue#(DiffCommit) diffCommit;
    method Bool diffCommitValid
  );
  method Action hostToCpu(Addr startpc);
  interface AxiMemMaster axiMem;
endinterface

module mkCore(Core);
  Ehr#(4, Addr)         pcReg <- mkEhr(START_PC);
  CsrFile                csrf <- mkCsrFile;
  RFile                    rf <- mkRFile;
  ICache               iCache <- mkICache;
  DCache               dCache <- mkDCache;
  AxiMemMaster        axiMux <- mkAxiArbiter2(iCache.axiMem, dCache.axiMem);
  Btb#(6)                 btb <- mkBtb; // 64-entry BTB
  Bht#(8)                 bht <- mkBht;
  Scoreboard#(6)           sb <- mkCFScoreboard;

  Ehr#(3, Bool)    exeEpoch <- mkEhr(False);
  Ehr#(3, Bool) decodeEpoch <- mkEhr(False);
  Reg#(Data)    scSuccValue <- mkRegU;

  Fifo#(2, F2D)           f2dFifo <- mkCFFifo;
  Fifo#(2, D2R)           d2rFifo <- mkCFFifo;
  Fifo#(2, R2E)           r2eFifo <- mkCFFifo;
  Fifo#(2, E2M)           e2mFifo <- mkCFFifo;
  Fifo#(2, M2W)           m2wFifo <- mkCFFifo;
  `IFDEF_DIFFTEST(
    Fifo#(2, DiffCommit) diffCommitFifo <- mkCFFifo;
  )

  rule doFetch (csrf.started);
    Addr predPc = btb.predPc(pcReg[0]);
    ExcpInfo fExcp = mkNoExcp;
    if (pcReg[0][1:0] != 2'b00) begin
      fExcp = mkExcp(`ECODE_ADE, `ESUBCODE_ADEF, pcReg[0]);
    end

    iCache.req(pcReg[0]);
    pcReg[0] <= predPc;

    f2dFifo.enq(F2D{pc: pcReg[0], predPc: predPc, excp: fExcp});
  endrule

  rule doDecode (csrf.started);
    let inst <- iCache.resp();
    DecodedInst dInst = decode(inst);

    let fetchPkt = f2dFifo.first();
    ExcpInfo dExcp = fetchPkt.excp;
    if (!dExcp.valid) begin
      if (dInst.iType == Unsupported) dExcp = mkExcp(`ECODE_INE, `ESUBCODE_NONE, fetchPkt.pc);
      else if (dInst.iType == Syscall) dExcp = mkExcp(`ECODE_SYS, `ESUBCODE_NONE, fetchPkt.pc);
      else if (dInst.iType == Break) dExcp = mkExcp(`ECODE_BRK, `ESUBCODE_NONE, fetchPkt.pc);
    end

    d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: ppc, dInst: dInst,
      `IFDEF_DIFFTEST(inst: inst,)
      excp: dExcp});
    f2dFifo.deq();
  endrule

  rule doRrf (csrf.started);
    let _Decode = d2rFifo.first();
    let rInst = _Decode.dInst;

    if (!sb.search1(rInst.src1) && !sb.search2(rInst.src2)) begin
      Data    rVal1 = rf.rd1(fromMaybe(?, rInst.src1));
      Data    rVal2 = rf.rd2(fromMaybe(?, rInst.src2));
      Data    csrVal = csrf.rd(fromMaybe(?, rInst.csr));

      r2eFifo.enq(R2E{pc: decodePkt.pc, predPc: decodePkt.predPc,
        `IFDEF_DIFFTEST(inst: decodePkt.inst,)
        rVal1: rVal1,
        rVal2: rVal2, csrVal: csrVal,
        rInst: rInst, excp: decodePkt.excp});
      sb.insert(rInst.dst);
      d2rFifo.deq();
    end
  endrule

  rule doExec (csrf.started);
    let rrfPkt = r2eFifo.first();
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
      end else begin
        btb.update(rrfPkt.pc, rrfPkt.predPc);
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

      e2mFifo.enq(E2M{pc: rrfPkt.pc,
        `ifdef CONFIG_DIFFTEST
        inst: rrfPkt.inst,
        `endif
        excp: eExcp,
        mask: rrfPkt.rInst.mask,
        eInst: tagged Valid eInst,
        epoch: rrfPkt.irExeEpoch});
    end
  endrule

  rule doMemory (csrf.started);
    let _Exec = e2mFifo.first();
    e2mFifo.deq();

    if (execPkt.epoch == exeEpoch[3]) begin
      if (isValid(execPkt.eInst)) begin
        let eInst = fromMaybe(?, execPkt.eInst);
        eInst.mask = execPkt.mask;

        ByteMask m = fromMaybe(5'b00000, execPkt.mask);
        let storePkt = selectStoreData(eInst.data, eInst.addr[1:0], m[3:0]);
        Bit#(WordSz) byteEn = tpl_1(storePkt);
        Data wData = tpl_2(storePkt);

        case (eInst.iType)
          Ld: begin
            dCache.req(MemReq { op: Ld, addr: eInst.addr, data: ?, byteEn: byteEn });
            `IFDEF_MTRACE($fwrite(stdout, "[MTRACE] LD pc:%x addr:%x be:%x\n", execPkt.pc, eInst.addr, byteEn));
          end
          St: begin
            dCache.req(MemReq { op: St, addr: eInst.addr, data: wData, byteEn: byteEn });
            `IFDEF_MTRACE($fwrite(stdout, "[MTRACE] ST pc:%x addr:%x be:%x data:%x raw:%x\n", execPkt.pc, eInst.addr, byteEn, wData, eInst.data));
          end
          Ll: begin
            dCache.req(MemReq { op: Lr, addr: eInst.addr, data: ?, byteEn: byteEn });
            `ifdef IFDEF_MTRACE($fwrite(stdout, "[MTRACE] LL pc:%x addr:%x be:%x\n", execPkt.pc, eInst.addr, byteEn));
          end
          Sc: begin
            dCache.req(MemReq { op: Sc, addr: eInst.addr, data: wData, byteEn: byteEn });
            `IFDEF_MTRACE($fwrite(stdout, "[MTRACE] SC pc:%x addr:%x be:%x data:%x raw:%x\n", execPkt.pc, eInst.addr, byteEn, wData, eInst.data));
          end
          Fence: begin
            dCache.req(MemReq { op: Fence, addr: ?, data: ?, byteEn: byteEn });
            `IFDEF_MTRACE($fwrite(stdout, "[MTRACE] FENCE pc:%x\n", execPkt.pc));
          end
          default: noAction;
        endcase

        m2wFifo.enq(M2W{pc: execPkt.pc,
          `IFDEF_DIFFTEST(inst: execPkt.inst),
          excp: execPkt.excp,
          mInst: tagged Valid eInst});
      end else begin
        m2wFifo.enq(M2W{pc: execPkt.pc,
          `IFDEF_DIFFTEST(inst: execPkt.inst),
          excp: execPkt.excp,
          mInst: tagged Invalid});
      end
    end else begin
      // Epoch mismatch, pass as Invalid to doWriteback to keep pipeline balance
      m2wFifo.enq(M2W{pc: execPkt.pc,
        `IFDEF_DIFFTEST(inst: execPkt.inst),
        excp: mkNoExcp,
        mInst: tagged Invalid});
    end
  endrule

  rule doWriteback (csrf.started);
    let _Mem = m2wFifo.first();
    m2wFifo.deq();

    if (isValid(_Mem.mInst)) begin
      let _mInst = fromMaybe(?, _Mem.mInst);
      if (_mInst.iType == Ld || _mInst.iType == Ll || _mInst.iType ==
        Sc) begin
        _mInst.data <- dCache.resp();
      end

      if (isValid(_mInst.dst)) begin
        rf.wr(fromMaybe(?, _mInst.dst), _mInst.data);
      end

      Data csrWrData = _mInst.iType == Csrw ? _mInst.addr : _mInst.data;
      csrf.wr(_mInst.iType == Csrw ? _mInst.csr : Invalid, csrWrData);

      Bool wen = isValid(_mInst.dst) && fromMaybe(0, _mInst.dst) != 0;
      // $fwrite(stdout, "commit: pc->%x, inst->%x\n", _Mem.pc, _Mem.inst);
      `ifdef CONFIG_DIFFTEST
      diffCommitFifo.enq(DiffCommit{
        pc: _Mem.pc,
        inst: _Mem.inst,
        wen: wen,
        wdest: fromMaybe(0, _mInst.dst),
        wdata: _mInst.data
      });
      `endif
    end
    sb.remove();
  endrule

  method ActionValue#(CpuToHostData) cpuToHost if (csrf.started);
    let ret <- csrf.cpuToHost;
    return ret;
  endmethod

  method Bool cpuToHostValid = csrf.cpuToHostValid;

  `ifdef CONFIG_DIFFTEST
  method ActionValue#(DiffCommit) diffCommit if (diffCommitFifo.notEmpty);
    let ret = diffCommitFifo.first;
    diffCommitFifo.deq;
    return ret;
  endmethod

  method Bool diffCommitValid = diffCommitFifo.notEmpty;
  `endif

  // TODO: this method will be remove
  method Action hostToCpu(Addr startpc) if (!csrf.started);
    csrf.start;
    pcReg[0] <= startpc;
  endmethod

  interface axiMem = axiMux;
endmodule
