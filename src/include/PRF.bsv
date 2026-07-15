import Types::*;
import ProcTypes::*;
import Vector::*;
import Ehr::*;
import OoOTypes::*;

// ============================================================
// Physical Register File — 64 entries, 6-port EHR
//
// Port layout:
//   [0]   Commit stage (commitWrite / setReadyCommit) and
//         Rename-stage allocate (clearReady).  Mutually exclusive.
//   [1]   CDB port 0 (Load)
//   [2]   CDB port 1 (ALU)
//   [3]   CDB port 2 (Mul)
//   [4]   CDB port 3 (Div)
//   [5]   All reads (rd1..rd5, isReady, isReady2)
//
// Each CDB port has its own dedicated EHR port so all four
// functional units can write back concurrently in the same cycle
// with no arbitration.  Reads on port [5] see every write that
// happened earlier in the same cycle (EHR ordering: 0..4 < 5).
// ============================================================

interface PRF;
  method Data rd1(PIndx p);
  method Data rd2(PIndx p);
  method Data rd3(PIndx p);
  method Data rd4(PIndx p);
  method Data rd5(PIndx p);
  method Action cdbWriteLoad(PIndx p, Data v);
  method Action cdbWriteALU (PIndx p, Data v);
  method Action cdbWriteMul (PIndx p, Data v);
  method Action cdbWriteDiv (PIndx p, Data v);
  method Action commitWrite(PIndx p, Data v);
  method Bool   isReady(PIndx p);
  method Bool   isReady2(PIndx p);
  method Action setReadyLoad(PIndx p);
  method Action setReadyALU (PIndx p);
  method Action setReadyMul (PIndx p);
  method Action setReadyDiv (PIndx p);
  method Action setReadyCommit(PIndx p);
  method Action clearReady(PIndx p);
endinterface

(* synthesize *)
module mkPRF(PRF);
  Vector#(64, Ehr#(6, Data)) pregfile <- replicateM(mkEhr(0));

  Vector#(64, Ehr#(6, Bool)) ready = newVector;
  for (Integer i = 0; i < 64; i = i + 1) begin
    ready[i] <- mkEhr(i < 32 ? True : False);
  end

  // ---------- All reads map to the highest port (5) ----------
  function Data read(PIndx p) = pregfile[p][5];
  method Data rd1(PIndx p) = read(p);
  method Data rd2(PIndx p) = read(p);
  method Data rd3(PIndx p) = read(p);
  method Data rd4(PIndx p) = read(p);
  method Data rd5(PIndx p) = read(p);
  method Bool isReady (PIndx p) = ready[p][5];
  method Bool isReady2(PIndx p) = ready[p][5];

  // ---------- Commit stage (port 0) ----------
  method Action commitWrite(PIndx p, Data v);
    if (p != 0) pregfile[p][0] <= v;
  endmethod
  method Action setReadyCommit(PIndx p);
    if (p != 0) ready[p][0] <= True;
  endmethod
  method Action clearReady(PIndx p);
    if (p != 0) ready[p][0] <= False;
  endmethod

  // ---------- CDB writes: one dedicated port per FU ----------
  method Action cdbWriteLoad(PIndx p, Data v);
    if (p != 0) pregfile[p][1] <= v;
  endmethod
  method Action cdbWriteALU(PIndx p, Data v);
    if (p != 0) pregfile[p][2] <= v;
  endmethod
  method Action cdbWriteMul(PIndx p, Data v);
    if (p != 0) pregfile[p][3] <= v;
  endmethod
  method Action cdbWriteDiv(PIndx p, Data v);
    if (p != 0) pregfile[p][4] <= v;
  endmethod

  method Action setReadyLoad(PIndx p);
    if (p != 0) ready[p][1] <= True;
  endmethod
  method Action setReadyALU(PIndx p);
    if (p != 0) ready[p][2] <= True;
  endmethod
  method Action setReadyMul(PIndx p);
    if (p != 0) ready[p][3] <= True;
  endmethod
  method Action setReadyDiv(PIndx p);
    if (p != 0) ready[p][4] <= True;
  endmethod
endmodule
