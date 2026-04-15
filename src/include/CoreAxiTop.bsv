import Types::*;
import ProcTypes::*;
import Core::*;
import AxiTypes::*;
`include "Autoconf.bsv"

interface CoreAxiTop;
  interface AxiMemMaster axiMem;
endinterface

(* synthesize *)
module mkCoreAxiTop(CoreAxiTop);
  Core core <- mkCore;

  interface axiMem = core.axiMem;
endmodule
