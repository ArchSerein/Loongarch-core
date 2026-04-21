import Types::*;
import ProcTypes::*;
import Core::*;
import AxiTypes::*;
`include "Autoconf.bsv"

interface CoreAxiTop;
  interface AxiMemMaster axiMem;
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
