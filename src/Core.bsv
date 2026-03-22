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

interface Core;
  method ActionValue#(CpuToHostData) cpuToHost;
  method Bool cpuToHostValid;
  `ifdef CONFIG_DIFFTEST
  method ActionValue#(DiffCommit) diffCommit;
  method Bool diffCommitValid;
  `endif
  method Action hostToCpu(Addr startpc);
  interface AxiMemMaster axiMem;
endinterface

typedef struct {
  Addr        pc;
  Addr        predPc;
  Bool        ifExeEpoch;
  Bool        ifDecodeEpoch;
}   F2D deriving(Bits, Eq);

typedef struct {
  Addr        pc;
  Addr        predPc;
  `ifdef CONFIG_DIFFTEST
  Instruction inst;
  `endif
  DecodedInst dInst;
  Bool        idExeEpoch;
}   D2R deriving(Bits, Eq);

typedef struct {
  Addr        pc;
  Addr        predPc;
  `ifdef CONFIG_DIFFTEST
  Instruction inst;
  `endif
  Data        rVal1;
  Data        rVal2;
  Data        csrVal;
  DecodedInst rInst;
  Bool        irExeEpoch;
}   R2E deriving(Bits, Eq);

typedef struct {
  Addr                pc;
  `ifdef CONFIG_DIFFTEST
  Instruction         inst;
  `endif
  Maybe#(ExecInst)    eInst;
}   E2M deriving(Bits, Eq);

typedef struct {
  Addr                pc;
  `ifdef CONFIG_DIFFTEST
  Instruction         inst;
  `endif
  Maybe#(ExecInst)    mInst;
}   M2W deriving(Bits, Eq);

module mkCore(Core);
  Ehr#(3, Addr)         pcReg <- mkEhr(?);
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

  Ehr#(3, Bool)    exeEpoch <- mkEhr(False);
  Ehr#(3, Bool) decodeEpoch <- mkEhr(False);
  Reg#(Data)    scSuccValue <- mkRegU;
  Ehr#(3, Bool) excInExec <- mkEhr(False);

  Fifo#(2, F2D)           f2dFifo <- mkCFFifo;
  Fifo#(2, D2R)           d2rFifo <- mkCFFifo;
  Fifo#(2, R2E)           r2eFifo <- mkCFFifo;
  Fifo#(2, E2M)           e2mFifo <- mkCFFifo;
  Fifo#(2, M2W)           m2wFifo <- mkCFFifo;
  Fifo#(2, DiffCommit) diffCommitFifo <- mkCFFifo;

  rule doFetch (csrf.started);
    iCache.req(pcReg[0]);
    Addr predPc = btb.predPc(pcReg[0]);

    f2dFifo.enq(F2D{pc: pcReg[0], predPc: predPc, ifExeEpoch: exeEpoch[0],
      ifDecodeEpoch: decodeEpoch[0]});
    pcReg[0] <= predPc;
  endrule

  rule doDecode (csrf.started);
    let inst <- iCache.resp();
    DecodedInst dInst = decode(inst);

    let _Fetch = f2dFifo.first();
    if (decodeEpoch[1] == _Fetch.ifDecodeEpoch && exeEpoch[1] ==
      _Fetch.ifExeEpoch) begin
      Addr    ppc;
      if (dInst.iType == Br) begin
        ppc = bht.ppcDP(_Fetch.pc, fromMaybe(?, dInst.imm) + _Fetch.pc);
      end else if (dInst.iType == J) begin
        ppc = fromMaybe(?, dInst.imm) + _Fetch.pc;
      end else begin
        ppc = _Fetch.predPc;
      end
      if (ppc != _Fetch.predPc) begin
        decodeEpoch[1] <= !decodeEpoch[1];
        pcReg[1] <= ppc;
      end

      d2rFifo.enq(D2R{pc: _Fetch.pc, predPc: ppc, dInst: dInst,
        `ifdef CONFIG_DIFFTEST
        inst: inst,
        `endif
        idExeEpoch: _Fetch.ifExeEpoch});
    end
    f2dFifo.deq();
  endrule

  rule doRrf (csrf.started);
    let _Decode = d2rFifo.first();
    let rInst = _Decode.dInst;

    if (!sb.search1(rInst.src1) && !sb.search2(rInst.src2)) begin
      Data    rVal1 = rf.rd1(fromMaybe(?, rInst.src1));
      Data    rVal2 = rf.rd2(fromMaybe(?, rInst.src2));
      Data    csrVal = csrf.rd(fromMaybe(?, rInst.csr));

      r2eFifo.enq(R2E{pc: _Decode.pc, predPc: _Decode.predPc,
        `ifdef CONFIG_DIFFTEST
        inst: _Decode.inst,
        `endif
        rVal1: rVal1,
        rVal2: rVal2, csrVal: csrVal,
        rInst: rInst, irExeEpoch: _Decode.idExeEpoch});
      sb.insert(rInst.dst);
      d2rFifo.deq();
    end
  endrule

  rule doExec (csrf.started);
    let _Rrf = r2eFifo.first();

    Bool doNormalExec = True;

    if (exeEpoch[2] == _Rrf.irExeEpoch) begin
      if (isValid(_Rrf.rInst.muldivFunc)) begin
        let mdFunc = fromMaybe(?, _Rrf.rInst.muldivFunc);
        if (mdFunc == MulW || mdFunc == MulhW || mdFunc == MulhWu) begin
           if (!mulInFlight) begin
             Bool is_signed = (mdFunc == MulW || mdFunc == MulhW);
             mulUnit.start(is_signed, _Rrf.rVal1, _Rrf.rVal2);
             mulInFlight <= True;
             doNormalExec = False;
           end else if (!mulUnit.finish) begin
             doNormalExec = False;
           end else begin
             mulInFlight <= False;
           end
        end else if (mdFunc == DivW || mdFunc == DivWu || mdFunc == ModW || mdFunc == ModWu) begin
           if (!divInFlight) begin
             Bool is_signed = (mdFunc == DivW || mdFunc == ModW);
             divUnit.start(is_signed, _Rrf.rVal1, _Rrf.rVal2);
             divInFlight <= True;
             doNormalExec = False;
           end else if (!divUnit.finish) begin
             doNormalExec = False;
           end else begin
             divInFlight <= False;
           end
        end
      end
    end

    if (doNormalExec) begin
      r2eFifo.deq();

      if (exeEpoch[2] == _Rrf.irExeEpoch) begin
        ExecInst eInst = exec(_Rrf.rInst, _Rrf.rVal1, _Rrf.rVal2, _Rrf.pc,
          _Rrf.predPc, _Rrf.csrVal);

        if (isValid(_Rrf.rInst.muldivFunc)) begin
          let mdFunc = fromMaybe(?, _Rrf.rInst.muldivFunc);
          if (mdFunc == MulW) eInst.data = mulUnit.result()[31:0];
          else if (mdFunc == MulhW || mdFunc == MulhWu) eInst.data = mulUnit.result()[63:32];
          else if (mdFunc == DivW || mdFunc == DivWu) eInst.data = divUnit.result()[31:0];
          else if (mdFunc == ModW || mdFunc == ModWu) eInst.data = divUnit.result()[63:32];
        end

      if (eInst.iType == Break) begin
        csrf.finish;
      end
      if (eInst.iType == Syscall) begin
        csrf.finish;
      end
      if (eInst.iType == Ertn) begin
        Addr era <- csrf.returnFromException;
        eInst.mispredict = True;
        eInst.addr = era;
        excInExec[1] <= True;
      end
      if (eInst.iType == Unsupported) begin
        $fwrite(stderr, "ERROR: Executing unsupported instruction at pc: %x. \
          Exiting\n", _Rrf.pc);
        $finish;
      end
      if (eInst.mispredict) begin
        exeEpoch[2] <= !exeEpoch[2];
        pcReg[2] <= eInst.addr;
        btb.update(_Rrf.pc, eInst.addr);
      end else begin
        btb.update(_Rrf.pc, _Rrf.predPc);
      end
      bht.update(_Rrf.pc, eInst.brTaken);

      e2mFifo.enq(E2M{pc: _Rrf.pc, 
      `ifdef CONFIG_DIFFTEST
      inst: _Rrf.inst,
      `endif
      eInst: tagged Valid eInst});
    end else begin
      e2mFifo.enq(E2M{pc: _Rrf.pc,
      `ifdef CONFIG_DIFFTEST
      inst: _Rrf.inst,
      `endif
      eInst: tagged Invalid});
    end
    end
  endrule

  rule clearExcInExec (csrf.started);
    excInExec[0] <= False;
  endrule

  rule doMemory (csrf.started);
    let _Exec = e2mFifo.first();
    e2mFifo.deq();

    if (isValid(_Exec.eInst)) begin
      let _eInst = fromMaybe(?, _Exec.eInst);
      case (_eInst.iType)
        Ld: begin
          // $fwrite(stdout, "pc-> %x read addr->%x\n", _Exec.pc, _eInst.addr);
          let req = MemReq { op: Ld, addr: _eInst.addr, data: ? };
          dCache.req(req);
        end
        St: begin
          // $fwrite(stdout, "pc-> %x write addr->%x, data->%x\n", _Exec.pc, _eInst.addr, _eInst.data);
          let req = MemReq { op: St, addr: _eInst.addr, data: _eInst.data };
          scSuccValue <= _eInst.data;
          dCache.req(req);
        end
        Ll: begin
          let req = MemReq { op: Lr, addr: _eInst.addr, data: ? };
          dCache.req(req);
        end
        Sc: begin
          let req = MemReq { op: Sc, addr: _eInst.addr, data: _eInst.data };
          dCache.req(req);
        end
        Fence: begin
          let req = MemReq { op: Fence, addr: ?, data: ? };
          dCache.req(req);
        end
        default: begin
        end
      endcase

      m2wFifo.enq(M2W{pc: _Exec.pc, 
      `ifdef CONFIG_DIFFTEST
      inst: _Exec.inst,
      `endif
      mInst: tagged Valid _eInst});
    end else begin
      m2wFifo.enq(M2W{pc: _Exec.pc,
      `ifdef CONFIG_DIFFTEST
      inst: _Exec.inst,
      `endif
      mInst: tagged Invalid});
    end
  endrule

  rule doWriteback (csrf.started && !excInExec[2]);
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

  method ActionValue#(CpuToHostData) cpuToHost;
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

  method Action hostToCpu(Addr startpc) if (!csrf.started);
    csrf.start;
    pcReg[0] <= startpc;
  endmethod

  interface axiMem = axiMux;
endmodule
