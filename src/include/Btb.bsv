import Types::*;
import ProcTypes::*;
import RegFile::*;
import Vector::*;

interface Btb#(numeric type indexSize);
  method Addr predPc(Addr pc);
  method Tuple2#(Bool, Addr) getTarget(Addr pc);
  method Action update(Addr thispc, Addr nextpc);
endinterface

module mkBtb(
    Btb#(indexSize)
)
provisos(
    Add#(indexSize, a__, 32),
    NumAlias#(TSub#(TSub#(AddrSz, 2), indexSize), tagSize)
);
  Vector#(TExp#(indexSize), Reg#(Addr))          targets <-
    replicateM(mkRegU);
  Vector#(TExp#(indexSize), Reg#(Bit#(tagSize)))    tags <-
    replicateM(mkRegU);
  Vector#(TExp#(indexSize), Reg#(Bool))            valid <-
    replicateM(mkReg(False));

  function Bit#(indexSize) getIndex(Addr pc) = truncate(pc >> 2);
  function Bit#(tagSize) getTag(Addr pc) = truncateLSB(pc);

  method Addr predPc(Addr pc);
    let index = getIndex(pc);
    let tag = getTag(pc);

    if (valid[index] && (tag == tags[index])) begin
      return targets[index];
    end else begin
      return(pc + 4);
    end
  endmethod

  method Tuple2#(Bool, Addr) getTarget(Addr pc);
    let index = getIndex(pc);
    let tag = getTag(pc);
    Bool hit = valid[index] && (tag == tags[index]);
    return tuple2(hit, targets[index]);
  endmethod

  method Action update(Addr thisPc, Addr nextPc);
    let index = getIndex(thisPc);
    let tag = getTag(thisPc);
    if (nextPc != thisPc + 4) begin
      valid[index] <= True;
      tags[index] <= tag;
      targets[index] <= nextPc;
    end
  endmethod
endmodule
