import Types::*;
import ProcTypes::*;
import Vector::*;
import Ehr::*;
import OoOTypes::*;

// ============================================================
// Physical Register File (PRF)
// 64 x 32-bit registers with ready bits
// EHR ports organized to avoid scheduling conflicts:
//   pregfile: [0]=cdbWrite, [1]=commitWrite, [2]=rd1/rd2 (DI), [3]=rd3/rd4 (CM src), [4]=rd5 (CM dst)
//   ready:    [0]=clearReady, [1]=setReady(CDB), [2]=setReadyCommit, [3]=isReady, [4]=isReady2
// ============================================================

interface PRF;
  method Data rd1(PIndx p);                  // read port 1 (DI stage)
  method Data rd2(PIndx p);                  // read port 2 (DI stage)
  method Data rd3(PIndx p);                  // read port 3 (CM stage, pSrc1)
  method Data rd4(PIndx p);                  // read port 4 (CM stage, pSrc2)
  method Data rd5(PIndx p);                  // read port 5 (CM stage, pDst result)
  method Action cdbWrite(PIndx p, Data v);   // CDB write port (writebackToPRF)
  method Action commitWrite(PIndx p, Data v); // commit write port (CM stage CSR)
  method Bool isReady(PIndx p);              // ready bit query 1 (DI stage)
  method Bool isReady2(PIndx p);             // ready bit query 2 (DI stage)
  method Action setReady(PIndx p);           // mark ready (after CDB writeback)
  method Action setReadyCommit(PIndx p);     // mark ready (after commit write)
  method Action clearReady(PIndx p);         // mark not ready (on alloc, RN stage)
endinterface

(* synthesize *)
module mkPRF(PRF);
  // 64 physical registers, EHR for write-before-read
  // port [0] = CDB write, port [1] = commit write, port [2] = DI read, port [3] = CM src read, port [4] = CM dst read
  Vector#(64, Ehr#(5, Data)) pregfile = newVector;
  for (Integer i = 0; i < 64; i = i + 1) begin
    pregfile[i] <- mkEhr(0);
  end

  // Ready bits: EHR with 5 ports for conflict-free concurrent access
  // Port [0]: clearReady (rename stage allocates new pDst)
  // Port [1]: setReady (CDB writeback completes a pDst)
  // Port [2]: setReadyCommit (commit write for CSR results)
  // Port [3]: isReady read 1 (DI stage checks, sees same-cycle writes)
  // Port [4]: isReady read 2 (second operand check in same rule)
  Vector#(64, Ehr#(5, Bool)) ready = newVector;
  for (Integer i = 0; i < 64; i = i + 1) begin
    if (i < 32)
      ready[i] <- mkEhr(True);   // P0-P31: initial arch mapping, ready
    else
      ready[i] <- mkEhr(False);  // P32-P63: speculative, not ready until written
  end

  function Data read(PIndx p);
    return pregfile[p][2];
  endfunction
  function Data readCm(PIndx p);
    return pregfile[p][3];
  endfunction
  function Data readCm2(PIndx p);
    return pregfile[p][4];
  endfunction

  method Data rd1(PIndx p) = read(p);
  method Data rd2(PIndx p) = read(p);
  method Data rd3(PIndx p) = readCm(p);
  method Data rd4(PIndx p) = readCm(p);
  method Data rd5(PIndx p) = readCm2(p);

  method Action cdbWrite(PIndx p, Data v);
    if (p != 0) begin
      pregfile[p][0] <= v;
    end
  endmethod

  method Action commitWrite(PIndx p, Data v);
    if (p != 0) begin
      pregfile[p][1] <= v;
    end
  endmethod

  method Bool isReady(PIndx p) = ready[p][3];
  method Bool isReady2(PIndx p) = ready[p][4];

  method Action setReady(PIndx p);
    if (p != 0) begin
      ready[p][1] <= True;
    end
  endmethod

  method Action setReadyCommit(PIndx p);
    if (p != 0) begin
      ready[p][2] <= True;
    end
  endmethod

  method Action clearReady(PIndx p);
    if (p != 0) begin
      ready[p][0] <= False;
    end
  endmethod
endmodule
