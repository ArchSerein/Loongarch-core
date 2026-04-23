import Types::*;
import ProcTypes::*;
import Core::*;
import AxiTypes::*;
`include "Autoconf.bsv"

interface CoreAxiTop;
  interface AxiMemMaster axiMem;
`ifdef CONFIG_DIFFTEST
  (* result = "diffTrace" *)
  method ActionValue#(Bit#(2464)) diffTrace;
  (* result = "diffTraceValid" *)
  method Bool diffTraceValid;
  (* result = "diffCommitBundle" *)
  method Bit#(142) diffCommitBundle;
  (* result = "diffRegsBundle" *)
  method Bit#(1024) diffRegsBundle;
  (* result = "diffCsrBundle" *)
  method Bit#(832) diffCsrBundle;
  (* result = "diffExcpBundle" *)
  method Bit#(130) diffExcpBundle;
  (* result = "diffStoreBundle" *)
  method Bit#(200) diffStoreBundle;
  (* result = "diffLoadBundle" *)
  method Bit#(136) diffLoadBundle;
  (* prefix = "" *)
  method Action diffTraceDeq;
  (* result = "diffStepValid" *)
  method Bool diffStepValid;
  (* result = "liveDiffCommitBundle" *)
  method Bit#(142) liveDiffCommitBundle;
  (* result = "liveDiffRegsBundle" *)
  method Bit#(1024) liveDiffRegsBundle;
  (* result = "liveDiffCsrBundle" *)
  method Bit#(832) liveDiffCsrBundle;
  (* result = "liveDiffExcpBundle" *)
  method Bit#(130) liveDiffExcpBundle;
  (* result = "liveDiffStoreBundle" *)
  method Bit#(200) liveDiffStoreBundle;
  (* result = "liveDiffLoadBundle" *)
  method Bit#(136) liveDiffLoadBundle;
`endif
`ifdef CONFIG_VSIM
  (* always_ready, always_enabled, prefix = "" *)
  method Action debugInput((* port = "break_point" *) Bool breakPoint,
                           (* port = "infor_flag" *) Bool inforFlag,
                           (* port = "reg_num" *) RIndx regNum);
  (* always_ready, result = "ws_valid" *)
  method Bool wsValid;
  (* always_ready, result = "rf_rdata" *)
  method Data rfRdata;
  (* always_ready, result = "debug0_wb_pc" *)
  method Addr debug0WbPc;
  (* always_ready, result = "debug0_wb_rf_wen" *)
  method Bit#(4) debug0WbRfWen;
  (* always_ready, result = "debug0_wb_rf_wnum" *)
  method RIndx debug0WbRfWnum;
  (* always_ready, result = "debug0_wb_rf_wdata" *)
  method Data debug0WbRfWdata;
  (* always_ready, result = "debug0_wb_inst" *)
  method Instruction debug0WbInst;
`endif
endinterface

(* synthesize *)
module mkCoreAxiTop(CoreAxiTop);
  Core core <- mkCore;

  interface axiMem = core.axiMem;
`ifdef CONFIG_DIFFTEST
  method ActionValue#(Bit#(2464)) diffTrace;
    let t <- core.diffTrace;
    return pack(t);
  endmethod
  method Bool diffTraceValid = core.diffTraceValid;
  method Bit#(142) diffCommitBundle = core.diffCommitBundle;
  method Bit#(1024) diffRegsBundle = core.diffRegsBundle;
  method Bit#(832) diffCsrBundle = core.diffCsrBundle;
  method Bit#(130) diffExcpBundle = core.diffExcpBundle;
  method Bit#(200) diffStoreBundle = core.diffStoreBundle;
  method Bit#(136) diffLoadBundle = core.diffLoadBundle;
  method Action diffTraceDeq;
    core.diffTraceDeq;
  endmethod
  method Bool diffStepValid = core.diffStepValid;
  method Bit#(142) liveDiffCommitBundle = core.liveDiffCommitBundle;
  method Bit#(1024) liveDiffRegsBundle = core.liveDiffRegsBundle;
  method Bit#(832) liveDiffCsrBundle = core.liveDiffCsrBundle;
  method Bit#(130) liveDiffExcpBundle = core.liveDiffExcpBundle;
  method Bit#(200) liveDiffStoreBundle = core.liveDiffStoreBundle;
  method Bit#(136) liveDiffLoadBundle = core.liveDiffLoadBundle;
`endif
`ifdef CONFIG_VSIM
  method Action debugInput(Bool breakPoint, Bool inforFlag, RIndx regNum);
    core.debugInput(breakPoint, inforFlag, regNum);
  endmethod
  method Bool wsValid = core.wsValid;
  method Data rfRdata = core.rfRdata;
  method Addr debug0WbPc = core.debug0WbPc;
  method Bit#(4) debug0WbRfWen = core.debug0WbRfWen;
  method RIndx debug0WbRfWnum = core.debug0WbRfWnum;
  method Data debug0WbRfWdata = core.debug0WbRfWdata;
  method Instruction debug0WbInst = core.debug0WbInst;
`endif
endmodule
