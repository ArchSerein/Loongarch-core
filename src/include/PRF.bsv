import Types::*;
import ProcTypes::*;
import Vector::*;
import Ehr::*;
import OoOTypes::*;

// ============================================================
// Physical Register File (PRF)
// 64 x 32-bit registers with ready bits
// Based on mkBypassRFile pattern, extended for OoO
// ============================================================

interface PRF;
  method Data rd1(PIndx p);           // read port 1 (RD stage)
  method Data rd2(PIndx p);           // read port 2 (RD stage)
  method Action cdbWrite(PIndx p, Data v);  // CDB write port
  method Bool isReady(PIndx p);       // ready bit query
  method Action setReady(PIndx p);    // mark ready (after CDB write)
  method Action clearReady(PIndx p);  // mark not ready (on alloc)
endinterface

(* synthesize *)
module mkPRF(PRF);
  // 64 physical registers, EHR for write-before-read
  // port [0] = CDB write, port [1] = read
  Vector#(64, Ehr#(2, Data)) pregfile = newVector;
  for (Integer i = 0; i < 64; i = i + 1) begin
    if (i == 0)
      pregfile[i] <- mkEhr(0);
    else
      pregfile[i] <- mkEhrU;
  end

  // Ready bits: P0-P31 start ready (initial arch mapping),
  // P32-P63 start not-ready (speculative, allocated on demand)
  Vector#(64, Reg#(Bool)) ready = newVector;
  for (Integer i = 0; i < 64; i = i + 1) begin
    if (i == 0)
      ready[i] <- mkReg(True);
    else if (i < 32)
      ready[i] <- mkReg(True);
    else
      ready[i] <- mkReg(False);
  end

  function Data read(PIndx p);
    return pregfile[p][1];
  endfunction

  method Data rd1(PIndx p) = read(p);
  method Data rd2(PIndx p) = read(p);

  method Action cdbWrite(PIndx p, Data v);
    if (p != 0) begin
      pregfile[p][0] <= v;
    end
  endmethod

  method Bool isReady(PIndx p) = ready[p];

  method Action setReady(PIndx p);
    if (p != 0) begin
      ready[p] <= True;
    end
  endmethod

  method Action clearReady(PIndx p);
    if (p != 0) begin
      ready[p] <= False;
    end
  endmethod
endmodule
