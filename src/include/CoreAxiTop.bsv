import Types::*;
import ProcTypes::*;
import CoreTypes::*;
import Core::*;
import AxiTypes::*;
`include "Autoconf.bsv"
`ifdef CONFIG_VSIM
`define CONFIG_WB_DEBUG
`define CONFIG_WB_DEBUG_INST
`endif
`ifdef CONFIG_FPGA
`define CONFIG_WB_DEBUG
`endif

interface CoreAxiTop;
  (* always_ready, always_enabled, prefix = "" *)
  method Action setInterrupt((* port = "intrpt" *) Bit#(8) val);
  interface AxiMemMaster axiMem;
`ifdef CONFIG_DIFFTEST
`ifdef CONFIG_BSIM
  (* result = "diffTrace" *)
  method ActionValue#(Bit#(2464)) diffTrace;
  (* result = "diffTraceValid" *)
  method Bool diffTraceValid;
`else
  (* always_ready, result = "diffStepValid" *)
  method Bool diffStepValid;
  (* always_ready, result = "liveDiffCommitBundle" *)
  method Bit#(142) liveDiffCommitBundle;
  (* always_ready, result = "liveDiffRegsBundle" *)
  method Bit#(1024) liveDiffRegsBundle;
  (* always_ready, result = "liveDiffCsrBundle" *)
  method Bit#(832) liveDiffCsrBundle;
  (* always_ready, result = "liveDiffExcpBundle" *)
  method Bit#(130) liveDiffExcpBundle;
  (* always_ready, result = "liveDiffStoreBundle" *)
  method Bit#(200) liveDiffStoreBundle;
  (* always_ready, result = "liveDiffLoadBundle" *)
  method Bit#(136) liveDiffLoadBundle;
`endif
`endif
`ifdef CONFIG_WB_DEBUG
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
`ifdef CONFIG_WB_DEBUG_INST
  (* always_ready, result = "debug0_wb_inst" *)
  method Instruction debug0WbInst;
`endif
`endif
endinterface

(* synthesize *)
module mkCoreAxiTop(CoreAxiTop);
  Core core <- mkCore;

  method Action setInterrupt(Bit#(8) val);
    core.setInterrupt(val);
  endmethod

  interface axiMem = core.axiMem;
`ifdef CONFIG_DIFFTEST
`ifdef CONFIG_BSIM
  method ActionValue#(Bit#(2464)) diffTrace;
    let t <- core.diffTrace;
    return pack(t);
  endmethod
  method Bool diffTraceValid = core.diffTraceValid;
`else
  method Bool diffStepValid = core.diffStepValid;
  method Bit#(142) liveDiffCommitBundle = core.liveDiffCommitBundle;
  method Bit#(1024) liveDiffRegsBundle = core.liveDiffRegsBundle;
  method Bit#(832) liveDiffCsrBundle = core.liveDiffCsrBundle;
  method Bit#(130) liveDiffExcpBundle = core.liveDiffExcpBundle;
  method Bit#(200) liveDiffStoreBundle = core.liveDiffStoreBundle;
  method Bit#(136) liveDiffLoadBundle = core.liveDiffLoadBundle;
`endif
`endif
`ifdef CONFIG_WB_DEBUG
  method Action debugInput(Bool breakPoint, Bool inforFlag, RIndx regNum);
    core.debugInput(breakPoint, inforFlag, regNum);
  endmethod
  method Bool wsValid = core.wsValid;
  method Data rfRdata = core.rfRdata;
  method Addr debug0WbPc = core.debug0WbPc;
  method Bit#(4) debug0WbRfWen = core.debug0WbRfWen;
  method RIndx debug0WbRfWnum = core.debug0WbRfWnum;
  method Data debug0WbRfWdata = core.debug0WbRfWdata;
`ifdef CONFIG_WB_DEBUG_INST
  method Instruction debug0WbInst = core.debug0WbInst;
`endif
`endif
endmodule
