import Types::*;
import ProcTypes::*;
import Core::*;
import AxiTypes::*;

interface CoreAxiTop;
  method ActionValue#(CpuToHostData) cpuToHost;
  method Bool cpuToHostValid;
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

  method Action hostToCpu(Addr startpc);
    core.hostToCpu(startpc);
  endmethod

  interface axiMem = core.axiMem;
endmodule
