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
  Bool                epoch;
}   E2M deriving(Bits, Eq);

typedef struct {
  Addr                pc;
  `ifdef CONFIG_DIFFTEST
  Instruction         inst;
  `endif
  ExcpInfo            excp;
  Maybe#(ExecInst)    mInst;
  Bool                epoch;
}   M2W deriving(Bits, Eq);

// Helper functions for optimization
function Data selectLoadData(Data rData, Bit#(2) offset, Bit#(4) rawEn, Bool signExt);
  Bit#(2) loadOffset = 2'b00;
  case (rawEn)
    4'b0001: loadOffset = offset;
    4'b0011: loadOffset = {offset[1], 1'b0};
    default: loadOffset = 2'b00;
  endcase

  Data shiftedData = rData >> {loadOffset, 3'b0};

  if (rawEn == 4'b0001) begin
    return signExt ? signExtend(shiftedData[7:0]) : zeroExtend(shiftedData[7:0]);
  end else if (rawEn == 4'b0011) begin
    return signExt ? signExtend(shiftedData[15:0]) : zeroExtend(shiftedData[15:0]);
  end else begin
    return shiftedData;
  end
endfunction

function Tuple2#(Bit#(4), Data) selectStoreData(Data d, Bit#(2) offset, Bit#(4) rawEn);
  Bit#(2) alignOff = 0;
  Bit#(4) byteEn = 0;
  Data wData = 0;

  case (rawEn)
    4'b0001: begin
      alignOff = offset;
      byteEn = 4'b0001 << alignOff;
      wData = zeroExtend(d[7:0]) << {alignOff, 3'b0};
    end
    4'b0011: begin
      alignOff = {offset[1], 1'b0};
      byteEn = 4'b0011 << alignOff;
      wData = zeroExtend(d[15:0]) << {alignOff, 3'b0};
    end
    4'b1111: begin
      alignOff = 2'b00;
      byteEn = 4'b1111;
      wData = d;
    end
    default: begin
      alignOff = 2'b00;
      byteEn = 4'b0000;
      wData = 0;
    end
  endcase
  return tuple2(byteEn, wData);
endfunction

module mkCore(Core);
  Ehr#(4, Addr)         pcReg <- mkEhr(?);
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
  Ehr#(3, Bool) decodeEpoch <- mkEhr(False);

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
    end
    // Always request to keep pipeline in sync, even if exception occurs
    iCache.req(pcReg[0]);

    f2dFifo.enq(F2D{pc: pcReg[0], predPc: predPc, ifExeEpoch: exeEpoch[0],
      ifDecodeEpoch: decodeEpoch[0], excp: fExcp});
    pcReg[0] <= predPc;
  endrule

  rule doDecode (csrf.started);
    let inst <- iCache.resp();
    DecodedInst dInst = decode(inst);

    let fetchPkt = f2dFifo.first();
    if (decodeEpoch[1] == fetchPkt.ifDecodeEpoch && exeEpoch[1] == fetchPkt.ifExeEpoch) begin
      ExcpInfo dExcp = fetchPkt.excp;
      if (!dExcp.valid) begin
        if (dInst.iType == Unsupported) dExcp = mkExcp(`ECODE_INE, `ESUBCODE_NONE, fetchPkt.pc);
        else if (dInst.iType == Syscall) dExcp = mkExcp(`ECODE_SYS, `ESUBCODE_NONE, fetchPkt.pc);
        else if (dInst.iType == Break) dExcp = mkExcp(`ECODE_BRK, `ESUBCODE_NONE, fetchPkt.pc);
      end

      Addr ppc;
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
    end

    if (doNormalExec) begin
      r2eFifo.deq();
      if (exeEpoch[2] == rrfPkt.irExeEpoch) begin
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
      end else begin
        e2mFifo.enq(E2M{pc: rrfPkt.pc,
          `ifdef CONFIG_DIFFTEST
          inst: rrfPkt.inst,
          `endif
          excp: mkNoExcp,
          mask: rrfPkt.rInst.mask,
          eInst: tagged Invalid,
          epoch: rrfPkt.irExeEpoch});
      end
    end
  endrule

  rule doMemory (csrf.started);
    let execPkt = e2mFifo.first();
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

        m2wFifo.enq(M2W{pc: execPkt.pc,
          `ifdef CONFIG_DIFFTEST
          inst: execPkt.inst,
          `endif
          excp: execPkt.excp,
          mInst: tagged Valid eInst,
          epoch: execPkt.epoch});
      end else begin
        m2wFifo.enq(M2W{pc: execPkt.pc,
          `ifdef CONFIG_DIFFTEST
          inst: execPkt.inst,
          `endif
          excp: execPkt.excp,
          mInst: tagged Invalid,
          epoch: execPkt.epoch});
      end
    end else begin
      // Epoch mismatch, pass as Invalid to doWriteback to keep pipeline balance
      m2wFifo.enq(M2W{pc: execPkt.pc,
        `ifdef CONFIG_DIFFTEST
        inst: execPkt.inst,
        `endif
        excp: mkNoExcp,
        mInst: tagged Invalid,
        epoch: execPkt.epoch});
    end
  endrule

  rule doWriteback (csrf.started);
    let memPkt = m2wFifo.first();
    m2wFifo.deq();

    if (memPkt.epoch == exeEpoch[0]) begin
      if (isValid(memPkt.mInst)) begin
        let mInst = fromMaybe(?, memPkt.mInst);
        Data rData = mInst.data;
        if (mInst.iType == Ld || mInst.iType == Ll || mInst.iType == Sc) begin
          rData <- dCache.resp();
          if (mInst.iType == Ld) begin
            ByteMask m = fromMaybe(5'b11111, mInst.mask);
            rData = selectLoadData(rData, mInst.addr[1:0], m[3:0], m[4] == 1'b1);
          end
          mInst.data = rData;
        end

        Bool has_int = csrf.hasInterrupt;
        ExcpInfo wbExcp = memPkt.excp;
        Bool wb_has_excp = has_int || wbExcp.valid;
        Bit#(6) wb_ecode = has_int ? `ECODE_INT : wbExcp.ecode;
        Bit#(9) wb_esubcode = has_int ? 0 : wbExcp.esubcode;

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

        $fwrite(stdout, "commit: pc->%x, inst->%x\n", memPkt.pc, memPkt.inst);
        `ifdef CONFIG_DIFFTEST
        // Compute nextPc for difftest synchronization:
        // - For branches/jumps that redirected: use the target address
        // - For sequential flow: use pc + 4
        Addr commitNextPc = mInst.mispredict ? mInst.addr : (memPkt.pc + 4);
        diffCommitFifo.enq(DiffCommit{
          pc: memPkt.pc,
          nextPc: commitNextPc,
          inst: memPkt.inst,
          wen: wen,
          wdest: fromMaybe(0, mInst.dst),
          wdata: mInst.data
        });
        `endif
      end
      sb.remove();
    end else begin
      // Flushed instruction, drain cache if necessary
      if (isValid(memPkt.mInst)) begin
        let mInst = fromMaybe(?, memPkt.mInst);
        if (mInst.iType == Ld || mInst.iType == Ll || mInst.iType == Sc) begin
           let _unused <- dCache.resp();
        end
      end
      sb.remove();
    end
  endrule

  method ActionValue#(CpuToHostData) cpuToHost = csrf.cpuToHost;
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
