import Types::*;
import Vector::*;
import Ehr::*;

interface Bht#(numeric type indexSize);
  method  Bool    predict(Addr pc);
  method  Action  update(Addr pc, Bool taken);
endinterface

module mkBht(Bht#(indexSize)) provisos(Add#(a__, indexSize, 32));
  Vector#(TExp#(indexSize), Ehr#(2, Bit#(2))) bhtArr <- replicateM(mkEhrU);

  function Bit#(indexSize) getBhtIndex(Addr pc);
    return truncate(pc >> 2);
  endfunction

  function Bit#(2) getBhtEntry(Bit#(indexSize) index, Bit#(1) port);
    return bhtArr[index][port];
  endfunction

  function Bit#(2) newDpBits(Bit#(2) dpBits, Bool taken);
    Bit#(2) newDp = case (dpBits)
    2'b00: (taken ? 2'b01 : 2'b00);
    2'b01: (taken ? 2'b10 : 2'b00);
    2'b10: (taken ? 2'b11 : 2'b01);
    2'b11: (taken ? 2'b11 : 2'b10);
  endcase;

    return newDp;
  endfunction

  method Action update(Addr pc, Bool taken);
    Bit#(indexSize) index = getBhtIndex(pc);
    let dpBits = getBhtEntry(index, 1);
    bhtArr[index][1] <= newDpBits(dpBits, taken);
  endmethod

  method Bool predict(Addr pc);
    Bit#(indexSize) index = getBhtIndex(pc);
    let dpBits = getBhtEntry(index, 0);
    return (dpBits[1] == 1'b1);
  endmethod
endmodule
