import SFifo::*;
import ProcTypes::*;

interface Scoreboard#(numeric type size);
  method Action insert(Maybe#(RIndx) r);
  method Action remove;
  method Bool search1(Maybe#(RIndx) r);
  method Bool search2(Maybe#(RIndx) r);
  method Bool search3(Maybe#(RIndx) r);
  method Action clear;
endinterface

function Bool isFound(Maybe#(RIndx) x, Maybe#(RIndx) k);
  if (x matches tagged Valid .xv &&& k matches tagged Valid .kv &&& kv ==
    xv) begin
    return True;
  end else begin
    return False;
  end
endfunction

module mkBypassScoreboard(Scoreboard#(size));
  SFifo#(size, Maybe#(RIndx), Maybe#(RIndx))  f <- mkBypassSFifo(isFound);

  method insert = f.enq;

  method remove = f.deq;

  method search1 = f.search;
  method search2 = f.search;
  method search3 = f.search;

  method clear = f.clear;
endmodule

module mkPipelineScoreboard(Scoreboard#(size));
  SFifo#(size, Maybe#(RIndx), Maybe#(RIndx)) f <- mkPipelineSFifo(isFound);

  method insert = f.enq;

  method remove = f.deq;

  method search1 = f.search;
  method search2 = f.search;
  method search3 = f.search;

  method clear = f.clear;
endmodule

module mkCFScoreboard(Scoreboard#(size));
  SFifo#(size, Maybe#(RIndx), Maybe#(RIndx)) f <- mkCFSFifo(isFound);

  method insert = f.enq;

  method remove = f.deq;

  method search1 = f.search;
  method search2 = f.search;
  method search3 = f.search;

  method clear = f.clear;
endmodule
