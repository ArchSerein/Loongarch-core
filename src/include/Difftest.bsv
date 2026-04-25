import Types::*;
import ProcTypes::*;
import DiffTypes::*;
import Fifo::*;
import Vector::*;
`include "Autoconf.bsv"

`ifdef CONFIG_DIFFTEST
interface Difftest;
  method Action enqTrace(DiffTrace t);
  method Bool enqTraceReady;
  method Action clearLive;
  method ActionValue#(DiffTrace) diffTrace;
  method Bool diffTraceValid;
  method Bit#(142) diffCommitBundle;
  method Bit#(1024) diffRegsBundle;
  method Bit#(832) diffCsrBundle;
  method Bit#(130) diffExcpBundle;
  method Bit#(200) diffStoreBundle;
  method Bit#(136) diffLoadBundle;
  method Action diffTraceDeq;
  method Bool diffStepValid;
  method Bit#(142) liveDiffCommitBundle;
  method Bit#(1024) liveDiffRegsBundle;
  method Bit#(832) liveDiffCsrBundle;
  method Bit#(130) liveDiffExcpBundle;
  method Bit#(200) liveDiffStoreBundle;
  method Bit#(136) liveDiffLoadBundle;
endinterface

function Bit#(8) diffStoreCode(IType iType, Bit#(4) byteEn, Bool scSuccess);
  Bit#(8) ret = 8'h00;
  if (iType == Sc) begin
    ret = scSuccess ? 8'h08 : 8'h00;
  end else if (iType == St) begin
    case (byteEn)
      4'b0001: ret = 8'h01;
      4'b0011: ret = 8'h02;
      4'b1111: ret = 8'h04;
      default: ret = 8'h00;
    endcase
  end
  return ret;
endfunction

function Bit#(8) diffLoadCode(IType iType, Maybe#(ByteMask) mask);
  Bit#(8) ret = 8'h00;
  if (iType == Ll) begin
    ret = 8'h20;
  end else if (iType == Ld && isValid(mask)) begin
    ByteMask m = fromMaybe(5'b0, mask);
    Bit#(4) byteEn = m[3:0];
    Bool isUnsigned = m[4] == 1'b0;
    case (byteEn)
      4'b0001: ret = isUnsigned ? 8'h02 : 8'h01;
      4'b0011: ret = isUnsigned ? 8'h08 : 8'h04;
      4'b1111: ret = 8'h10;
      default: ret = 8'h00;
    endcase
  end
  return ret;
endfunction

function Bit#(142) diffCommitBundleOf(DiffCommit c);
  return {
    pack(c.valid),
    c.pc,
    c.nextPc,
    c.inst,
    pack(c.wen),
    c.wdest,
    c.wdata,
    pack(c.skip),
    pack(c.isTlbfill),
    c.tlbfillIndex
  };
endfunction

function Bit#(1024) diffRegsBundleOf(DiffArchGRegState r);
  return {
    r.gpr[0], r.gpr[1], r.gpr[2], r.gpr[3],
    r.gpr[4], r.gpr[5], r.gpr[6], r.gpr[7],
    r.gpr[8], r.gpr[9], r.gpr[10], r.gpr[11],
    r.gpr[12], r.gpr[13], r.gpr[14], r.gpr[15],
    r.gpr[16], r.gpr[17], r.gpr[18], r.gpr[19],
    r.gpr[20], r.gpr[21], r.gpr[22], r.gpr[23],
    r.gpr[24], r.gpr[25], r.gpr[26], r.gpr[27],
    r.gpr[28], r.gpr[29], r.gpr[30], r.gpr[31]
  };
endfunction

function Bit#(832) diffCsrBundleOf(DiffArchCsrState c);
  return {
    c.crmd, c.prmd, c.euen, c.ecfg,
    c.era, c.badv, c.eentry, c.tlbidx,
    c.tlbehi, c.tlbelo0, c.tlbelo1, c.asid,
    c.pgdl, c.pgdh, c.save0, c.save1,
    c.save2, c.save3, c.tid, c.tcfg,
    c.tval, c.llbctl, c.tlbrentry, c.dmw0,
    c.dmw1, c.estat
  };
endfunction

function Bit#(130) diffExcpBundleOf(DiffExcpEvent e);
  return {
    pack(e.excpValid),
    pack(e.eret),
    e.interrupt,
    e.exception,
    e.exceptionPC,
    e.exceptionInst
  };
endfunction

function Bit#(200) diffStoreBundleOf(DiffStoreEvent s);
  return {
    s.valid,
    s.paddr,
    s.vaddr,
    s.data
  };
endfunction

function Bit#(136) diffLoadBundleOf(DiffLoadEvent l);
  return {
    l.valid,
    l.paddr,
    l.vaddr
  };
endfunction

function DiffStoreEvent diffStoreEventOf(Maybe#(DiffMemOp) diffMemInfo,
    IType iType, Maybe#(ByteMask) mask, Data result);
  DiffStoreEvent ret = DiffStoreEvent{
    valid: 0,
    paddr: 0,
    vaddr: 0,
    data: 0
  };

  if (diffMemInfo matches tagged Valid .diffMem) begin
    if (diffMem.isStore && (!diffMem.isSc || result == scSucc)) begin
      ret = DiffStoreEvent{
        valid: diffStoreCode(iType, fromMaybe(5'b0, mask)[3:0], result == scSucc),
        paddr: zeroExtend(diffMem.paddr),
        vaddr: zeroExtend(diffMem.vaddr),
        data: zeroExtend(diffMem.storeData)
      };
    end
  end

  return ret;
endfunction

function DiffLoadEvent diffLoadEventOf(Maybe#(DiffMemOp) diffMemInfo,
    IType iType, Maybe#(ByteMask) mask);
  DiffLoadEvent ret = DiffLoadEvent{
    valid: 0,
    paddr: 0,
    vaddr: 0
  };

  if (diffMemInfo matches tagged Valid .diffMem) begin
    if (diffMem.isLoad) begin
      ret = DiffLoadEvent{
        valid: diffLoadCode(iType, mask),
        paddr: zeroExtend(diffMem.paddr),
        vaddr: zeroExtend(diffMem.vaddr)
      };
    end
  end

  return ret;
endfunction

module mkDifftest(Difftest);
  Fifo#(2, DiffTrace) diffTraceFifo <- mkCFFifo;
  Reg#(Bool) liveDiffStepValidReg <- mkReg(False);
  Reg#(Bit#(142)) liveDiffCommitBundleReg <- mkReg(0);
  Reg#(Bit#(1024)) liveDiffRegsBundleReg <- mkReg(0);
  Reg#(Bit#(832)) liveDiffCsrBundleReg <- mkReg(0);
  Reg#(Bit#(130)) liveDiffExcpBundleReg <- mkReg(0);
  Reg#(Bit#(200)) liveDiffStoreBundleReg <- mkReg(0);
  Reg#(Bit#(136)) liveDiffLoadBundleReg <- mkReg(0);

  method Action enqTrace(DiffTrace t);
    diffTraceFifo.enq(t);
    liveDiffStepValidReg <= True;
    liveDiffCommitBundleReg <= diffCommitBundleOf(t.commit);
    liveDiffRegsBundleReg <= diffRegsBundleOf(t.regs);
    liveDiffCsrBundleReg <= diffCsrBundleOf(t.csr);
    liveDiffExcpBundleReg <= diffExcpBundleOf(t.excp);
    liveDiffStoreBundleReg <= diffStoreBundleOf(t.store);
    liveDiffLoadBundleReg <= diffLoadBundleOf(t.load);
  endmethod

  method Bool enqTraceReady = diffTraceFifo.notFull;

  method Action clearLive;
    liveDiffStepValidReg <= False;
  endmethod

  method ActionValue#(DiffTrace) diffTrace if (diffTraceFifo.notEmpty);
    let ret = diffTraceFifo.first;
    diffTraceFifo.deq;
    return ret;
  endmethod

  method Bool diffTraceValid = diffTraceFifo.notEmpty;
  method Bit#(142) diffCommitBundle if (diffTraceFifo.notEmpty) =
    diffCommitBundleOf(diffTraceFifo.first.commit);
  method Bit#(1024) diffRegsBundle if (diffTraceFifo.notEmpty) =
    diffRegsBundleOf(diffTraceFifo.first.regs);
  method Bit#(832) diffCsrBundle if (diffTraceFifo.notEmpty) =
    diffCsrBundleOf(diffTraceFifo.first.csr);
  method Bit#(130) diffExcpBundle if (diffTraceFifo.notEmpty) =
    diffExcpBundleOf(diffTraceFifo.first.excp);
  method Bit#(200) diffStoreBundle if (diffTraceFifo.notEmpty) =
    diffStoreBundleOf(diffTraceFifo.first.store);
  method Bit#(136) diffLoadBundle if (diffTraceFifo.notEmpty) =
    diffLoadBundleOf(diffTraceFifo.first.load);

  method Action diffTraceDeq if (diffTraceFifo.notEmpty);
    diffTraceFifo.deq;
  endmethod

  method Bool diffStepValid = liveDiffStepValidReg;
  method Bit#(142) liveDiffCommitBundle = liveDiffCommitBundleReg;
  method Bit#(1024) liveDiffRegsBundle = liveDiffRegsBundleReg;
  method Bit#(832) liveDiffCsrBundle = liveDiffCsrBundleReg;
  method Bit#(130) liveDiffExcpBundle = liveDiffExcpBundleReg;
  method Bit#(200) liveDiffStoreBundle = liveDiffStoreBundleReg;
  method Bit#(136) liveDiffLoadBundle = liveDiffLoadBundleReg;
endmodule
`endif
