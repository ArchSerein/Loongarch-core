import Types::*;
import ProcTypes::*;
import Core::*;
import AxiTypes::*;
`include "Autoconf.bsv"

interface CoreAxiTop;
  method ActionValue#(CpuToHostData) cpuToHost;
  method Bool cpuToHostValid;
`ifdef CONFIG_DIFFTEST
  method ActionValue#(DiffTrace) diffTrace;
  method Bool diffTraceValid;
`endif
  method Action hostToCpu(Addr startpc);
  interface AxiMemMaster axiMem;
endinterface

(* synthesize *)
module mkCoreAxiTop(CoreAxiTop);
  Core core <- mkCore;

  method ActionValue#(CpuToHostData) cpuToHost;
    let x <- core.cpuToHost;
    return x;
  endmethod

  method Bool cpuToHostValid = core.cpuToHostValid;

`ifdef CONFIG_DIFFTEST
  method ActionValue#(DiffTrace) diffTrace;
    let x <- core.diffTrace;
    return x;
  endmethod

  method Bool diffTraceValid = core.diffTraceValid;
`endif

  method Action hostToCpu(Addr startpc);
    core.hostToCpu(startpc);
  endmethod

  interface axiMem = core.axiMem;
endmodule
