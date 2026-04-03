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
  Bool      valid;
  Bit#(6)   ecode;
  Bit#(9)   esubcode;
  Addr      badv;
} ExcpInfo deriving(Bits, Eq);

function ExcpInfo mkNoExcp;
  return ExcpInfo{valid: False, ecode: 0, esubcode: 0, badv: 0};
endfunction

function ExcpInfo mkExcp(Bit#(6) ecode, Bit#(9) esubcode, Addr badv);
  return ExcpInfo{valid: True, ecode: ecode, esubcode: esubcode, badv: badv};
endfunction

typedef struct {
  Addr        pc;
  Addr        predPc;
  Bool        ifExeEpoch;
  Bool        ifDecodeEpoch;
  ExcpInfo    excp;
}   F2D deriving(Bits, Eq);

typedef struct {
  Addr        pc;
  Addr        predPc;
  `ifdef CONFIG_DIFFTEST
  Instruction inst;
  `endif
  DecodedInst dInst;
  Bool        idExeEpoch;
  ExcpInfo    excp;
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
  ExcpInfo    excp;
}   R2E deriving(Bits, Eq);

typedef struct {
  Addr                pc;
  `ifdef CONFIG_DIFFTEST
  Instruction         inst;
  `endif
  ExcpInfo            excp;
  Maybe#(ByteMask)    mask;
  Maybe#(ExecInst)    eInst;
}   E2M deriving(Bits, Eq);

typedef struct {
  Addr                pc;
  `ifdef CONFIG_DIFFTEST
  Instruction         inst;
  `endif
  ExcpInfo            excp;
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
    Addr predPc = btb.predPc(pcReg[0]);
    ExcpInfo fExcp = mkNoExcp;
    if (pcReg[0][1:0] != 2'b00) begin
      fExcp = mkExcp(`ECODE_ADE, `ESUBCODE_ADEF, pcReg[0]);
    end else begin
      iCache.req(pcReg[0]);
    end

    f2dFifo.enq(F2D{pc: pcReg[0], predPc: predPc, ifExeEpoch: exeEpoch[0],
      ifDecodeEpoch: decodeEpoch[0], excp: fExcp});
    pcReg[0] <= predPc;
  endrule

  rule doDecode (csrf.started);
    let inst <- iCache.resp();
    DecodedInst dInst = decode(inst);

    let fetchPkt = f2dFifo.first();
    if (decodeEpoch[1] == fetchPkt.ifDecodeEpoch && exeEpoch[1] ==
      fetchPkt.ifExeEpoch) begin
      ExcpInfo dExcp = fetchPkt.excp;
      if (!dExcp.valid && dInst.iType == Unsupported) begin
        dExcp = mkExcp(`ECODE_INE, `ESUBCODE_NONE, fetchPkt.pc);
      end
      if (!dExcp.valid && dInst.iType == Syscall) begin
        dExcp = mkExcp(`ECODE_SYS, `ESUBCODE_NONE, fetchPkt.pc);
      end
      if (!dExcp.valid && dInst.iType == Break) begin
        dExcp = mkExcp(`ECODE_BRK, `ESUBCODE_NONE, fetchPkt.pc);
      end

      Addr    ppc;
      if (dInst.iType == Br) begin
        ppc = bht.ppcDP(fetchPkt.pc, fromMaybe(?, dInst.imm) + fetchPkt.pc);
      end else if (dInst.iType == J) begin
        ppc = fromMaybe(?, dInst.imm) + fetchPkt.pc;
      end else begin
        ppc = fetchPkt.predPc;
      end
      if (ppc != fetchPkt.predPc) begin
        decodeEpoch[1] <= !decodeEpoch[1];
        pcReg[1] <= ppc;
      end

      d2rFifo.enq(D2R{pc: fetchPkt.pc, predPc: ppc, dInst: dInst,
        `ifdef CONFIG_DIFFTEST
        inst: inst,
        `endif
        idExeEpoch: fetchPkt.ifExeEpoch, excp: dExcp});
    end
    f2dFifo.deq();
  endrule

  rule doRrf (csrf.started);
    let decodePkt = d2rFifo.first();
    let rInst = decodePkt.dInst;

    if (!sb.search1(rInst.src1) && !sb.search2(rInst.src2)) begin
      Data    rVal1 = rf.rd1(fromMaybe(?, rInst.src1));
      Data    rVal2 = rf.rd2(fromMaybe(?, rInst.src2));
      Data    csrVal = csrf.rd(fromMaybe(?, rInst.csr));

      r2eFifo.enq(R2E{pc: decodePkt.pc, predPc: decodePkt.predPc,
        `ifdef CONFIG_DIFFTEST
        inst: decodePkt.inst,
        `endif
        rVal1: rVal1,
        rVal2: rVal2, csrVal: csrVal,
        rInst: rInst, irExeEpoch: decodePkt.idExeEpoch, excp: decodePkt.excp});
      sb.insert(rInst.dst);
      d2rFifo.deq();
    end
  endrule

  rule doExec (csrf.started);
    let rrfPkt = r2eFifo.first();

    Bool doNormalExec = True;

    if (exeEpoch[2] == rrfPkt.irExeEpoch) begin
      if (isValid(rrfPkt.rInst.muldivFunc)) begin
        let mdFunc = fromMaybe(?, rrfPkt.rInst.muldivFunc);
        if (mdFunc == MulW || mdFunc == MulhW || mdFunc == MulhWu) begin
           if (!mulInFlight) begin
             Bool is_signed = (mdFunc == MulW || mdFunc == MulhW);
             mulUnit.start(is_signed, rrfPkt.rVal1, rrfPkt.rVal2);
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
    end

    if (doNormalExec) begin
      r2eFifo.deq();

      if (exeEpoch[2] == rrfPkt.irExeEpoch) begin
        ExecInst eInst = exec(rrfPkt.rInst, rrfPkt.rVal1, rrfPkt.rVal2, rrfPkt.pc,
          rrfPkt.predPc, rrfPkt.csrVal);
        ExcpInfo eExcp = rrfPkt.excp;

        if (isValid(rrfPkt.rInst.muldivFunc)) begin
          let mdFunc = fromMaybe(?, rrfPkt.rInst.muldivFunc);
          if (mdFunc == MulW) eInst.data = truncate(mulUnit.result());
          else if (mdFunc == MulhW || mdFunc == MulhWu) eInst.data = truncateLSB(mulUnit.result());
          else if (mdFunc == DivW || mdFunc == DivWu) eInst.data = truncate(divUnit.result());
          else if (mdFunc == ModW || mdFunc == ModWu) eInst.data = truncateLSB(divUnit.result());
        end

      if (eInst.iType == Ertn) begin
        Addr era <- csrf.returnFromException;
        eInst.mispredict = True;
        eInst.addr = era;
        excInExec[1] <= True;
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
        if (rawEn == 4'b0011)
          exAle = (eInst.addr[0] != 1'b0);
        else if (rawEn == 4'b1111)
          exAle = (eInst.addr[1:0] != 2'b00);
        if (exAle)
          eExcp = mkExcp(`ECODE_ALE, `ESUBCODE_NONE, eInst.addr);
      end

      e2mFifo.enq(E2M{pc: rrfPkt.pc, 
      `ifdef CONFIG_DIFFTEST
      inst: rrfPkt.inst,
      `endif
      excp: eExcp,
      mask: rrfPkt.rInst.mask,
      eInst: tagged Valid eInst});
    end else begin
      e2mFifo.enq(E2M{pc: rrfPkt.pc,
      `ifdef CONFIG_DIFFTEST
      inst: rrfPkt.inst,
      `endif
      excp: mkNoExcp,
      mask: rrfPkt.rInst.mask,
      eInst: tagged Invalid});
    end
    end
  endrule

  rule clearExcInExec (csrf.started);
    excInExec[0] <= False;
  endrule

  rule doMemory (csrf.started);
    let execPkt = e2mFifo.first();
    e2mFifo.deq();

    if (isValid(execPkt.eInst)) begin
      let eInst = fromMaybe(?, execPkt.eInst);
      eInst.mask = execPkt.mask;

      ByteMask m = fromMaybe(5'b00000, execPkt.mask);
      Bit#(WordSz) rawEn = truncate(m);
      Bit#(2) offset = eInst.addr[1:0];
      Bit#(2) alignOff = 0;
      Bit#(WordSz) byteEn = 0;
      Data wData = 0;

      case (rawEn)
        4'b0001: begin
          alignOff = offset;
          byteEn = 4'b0001 << alignOff;
          wData = zeroExtend(eInst.data[7:0]) << {alignOff, 3'b0};
        end
        4'b0011: begin
          alignOff = {offset[1], 1'b0};
          byteEn = 4'b0011 << alignOff;
          wData = zeroExtend(eInst.data[15:0]) << {alignOff, 3'b0};
        end
        4'b1111: begin
          alignOff = 2'b00;
          byteEn = 4'b1111;
          wData = eInst.data;
        end
        default: begin
          alignOff = 2'b00;
          byteEn = 4'b0000;
          wData = 0;
        end
      endcase

      case (eInst.iType)
        Ld: begin
          let req = MemReq { op: Ld, addr: eInst.addr, data: ?, byteEn: byteEn };
          `ifdef CONFIG_MTRACE
          $fwrite(stdout, "[MTRACE] LD pc:%x addr:%x be:%x\n", execPkt.pc, eInst.addr, byteEn);
          `endif
          dCache.req(req);
        end
        St: begin
          let req = MemReq { op: St, addr: eInst.addr, data: wData, byteEn: byteEn };
          `ifdef CONFIG_MTRACE
          $fwrite(stdout, "[MTRACE] ST pc:%x addr:%x be:%x data:%x raw:%x\n", execPkt.pc, eInst.addr, byteEn, wData, eInst.data);
          `endif
          scSuccValue <= eInst.data;
          dCache.req(req);
        end
        Ll: begin
          let req = MemReq { op: Lr, addr: eInst.addr, data: ?, byteEn: byteEn };
          `ifdef CONFIG_MTRACE
          $fwrite(stdout, "[MTRACE] LL pc:%x addr:%x be:%x\n", execPkt.pc, eInst.addr, byteEn);
          `endif
          dCache.req(req);
        end
        Sc: begin
          let req = MemReq { op: Sc, addr: eInst.addr, data: wData, byteEn: byteEn };
          `ifdef CONFIG_MTRACE
          $fwrite(stdout, "[MTRACE] SC pc:%x addr:%x be:%x data:%x raw:%x\n", execPkt.pc, eInst.addr, byteEn, wData, eInst.data);
          `endif
          dCache.req(req);
        end
        Fence: begin
          let req = MemReq { op: Fence, addr: ?, data: ?, byteEn: byteEn };
          `ifdef CONFIG_MTRACE
          $fwrite(stdout, "[MTRACE] FENCE pc:%x\n", execPkt.pc);
          `endif
          dCache.req(req);
        end
        default: begin
        end
      endcase

      m2wFifo.enq(M2W{pc: execPkt.pc,
      `ifdef CONFIG_DIFFTEST
      inst: execPkt.inst,
      `endif
      excp: execPkt.excp,
      mInst: tagged Valid eInst});
    end else begin
      m2wFifo.enq(M2W{pc: execPkt.pc,
      `ifdef CONFIG_DIFFTEST
      inst: execPkt.inst,
      `endif
      excp: execPkt.excp,
      mInst: tagged Invalid});
    end
  endrule

  rule doWriteback (csrf.started && !excInExec[2]);
    let memPkt = m2wFifo.first();
    m2wFifo.deq();

    if (isValid(memPkt.mInst)) begin
      let mInst = fromMaybe(?, memPkt.mInst);
      Data rData = mInst.data;
      if (mInst.iType == Ld || mInst.iType == Ll || mInst.iType ==
        Sc) begin
        rData <- dCache.resp();

        if (mInst.iType == Ld) begin
          ByteMask m = fromMaybe(5'b11111, mInst.mask);
          Bool signExt = m[4] == 1'b1;
          Bit#(4) rawEn = m[3:0];
          Bit#(2) offset = mInst.addr[1:0];
          Bit#(2) loadOffset = 2'b00;

          case (rawEn)
            4'b0001: loadOffset = offset;
            4'b0011: loadOffset = {offset[1], 1'b0};
            default: loadOffset = 2'b00;
          endcase

          Data shiftedData = rData >> {loadOffset, 3'b0};

          if (rawEn == 4'b0001) begin
             if (signExt)
                rData = signExtend(shiftedData[7:0]);
             else
                rData = zeroExtend(shiftedData[7:0]);
          end else if (rawEn == 4'b0011) begin
             if (signExt)
                rData = signExtend(shiftedData[15:0]);
             else
                rData = zeroExtend(shiftedData[15:0]);
           end else begin
             rData = shiftedData;
           end
        end
        mInst.data = rData;
      end

      Bool has_int = csrf.hasInterrupt;
      ExcpInfo wbExcp = memPkt.excp;

      Bit#(6) wb_ecode = 0;
      Bit#(9) wb_esubcode = 0;
      Addr wb_pc = memPkt.pc;
      Bool wb_has_excp = has_int || wbExcp.valid;

      if (has_int) begin
        wb_ecode = `ECODE_INT;
      end else if (wbExcp.valid) begin
        wb_ecode = wbExcp.ecode;
        wb_esubcode = wbExcp.esubcode;
        wb_pc = memPkt.pc;
      end

      if (wb_has_excp) begin
        Addr exEntry <- csrf.raiseException(wb_ecode, wb_esubcode, wb_pc);
        exeEpoch[2] <= !exeEpoch[2];
        pcReg[2] <= exEntry;
      end else begin
        if (isValid(mInst.dst)) begin
          rf.wr(fromMaybe(?, mInst.dst), mInst.data);
        end

        Bool isCsrWrite = (mInst.iType == Csrw || mInst.iType == Csrxchg);
        Data csrWrData = isCsrWrite ? mInst.addr : mInst.data;
        csrf.wr(isCsrWrite ? mInst.csr : Invalid, csrWrData);

        Bool wen = isValid(mInst.dst) && fromMaybe(0, mInst.dst) != 0;
      end
      $fwrite(stdout, "commit: pc->%x, inst->%x\n", memPkt.pc, memPkt.inst);
      // $fwrite(stdout, "commit: pc->%x\n", memPkt.pc);
      `ifdef CONFIG_DIFFTEST
      diffCommitFifo.enq(DiffCommit{
        pc: memPkt.pc,
        inst: memPkt.inst,
        wen: wen,
        wdest: fromMaybe(0, mInst.dst),
        wdata: mInst.data
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
