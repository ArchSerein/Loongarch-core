import Types::*;
import ProcTypes::*;
import Vector::*;
import Ehr::*;
`include "Autoconf.bsv"

interface RFile;
  method Action wr(RIndx rindx, Data data);
  method Data rd1(RIndx rindx);
  method Data rd2(RIndx rindx);
  `IFDEF_DIFFTEST(method DiffArchGRegState diffSnapshot;)
  `IFDEF_DIFFTEST(method DiffArchGRegState diffSnapshotAfterWrite(Maybe#(RIndx) rindx, Data data);)
endinterface

(* synthesize *)
module mkRFile(RFile);
  Vector#(32, Reg#(Data)) rfile <- replicateM(mkReg(0));

  function Data read(RIndx rindx);
    return rfile[rindx];
  endfunction

  method Action wr(RIndx rindx, Data data);
    if (rindx != 0) begin
      rfile[rindx] <= data;
    end
  endmethod

  method Data rd1(RIndx rindx) = read(rindx);
  method Data rd2(RIndx rindx) = read(rindx);

  `IFDEF_DIFFTEST(
  method DiffArchGRegState diffSnapshot;
    Vector#(32, Data) snap = newVector;
    for (Integer i = 0; i < 32; i = i + 1) begin
      snap[i] = rfile[i];
    end
    return DiffArchGRegState{gpr: snap};
  endmethod

  method DiffArchGRegState diffSnapshotAfterWrite(Maybe#(RIndx) rindx, Data data);
    Vector#(32, Data) snap = newVector;
    for (Integer i = 0; i < 32; i = i + 1) begin
      snap[i] = rfile[i];
    end
    if (rindx matches tagged Valid .idx &&& idx != 0) begin
      snap[idx] = data;
    end
    return DiffArchGRegState{gpr: snap};
  endmethod
  )
endmodule

(* synthesize *)
module mkBypassRFile(RFile);
  Vector#(32, Ehr#(2, Data)) rfile <- replicateM(mkEhr(0));

  function Data read(RIndx rindx);
    return rfile[rindx][1];
  endfunction

  method Action wr(RIndx rindx, Data data);
    if (rindx != 0) begin
      rfile[rindx][0] <= data;
    end
  endmethod

  method Data rd1(RIndx rindx) = read(rindx);
  method Data rd2(RIndx rindx) = read(rindx);

  `IFDEF_DIFFTEST(
  method DiffArchGRegState diffSnapshot;
    Vector#(32, Data) snap = newVector;
    for (Integer i = 0; i < 32; i = i + 1) begin
      snap[i] = rfile[i][1];
    end
    return DiffArchGRegState{gpr: snap};
  endmethod

  method DiffArchGRegState diffSnapshotAfterWrite(Maybe#(RIndx) rindx, Data data);
    Vector#(32, Data) snap = newVector;
    for (Integer i = 0; i < 32; i = i + 1) begin
      snap[i] = rfile[i][1];
    end
    if (rindx matches tagged Valid .idx &&& idx != 0) begin
      snap[idx] = data;
    end
    return DiffArchGRegState{gpr: snap};
  endmethod
  )
endmodule
