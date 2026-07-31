`include "Autoconf.bsv"

import Types::*;
import ProcTypes::*;
import Vector::*;
import OoOTypes::*;

// ============================================================
// Physical Register File - 64 entries with centralized write requests.
//
// Data/ready reads only observe the registered PRF state. Producer methods
// drive per-source request wires; canonicalize merges them at the cycle
// boundary. This deliberately removes the old EHR read bypass chain from
// writeback/commit into dispatch.
// ============================================================

typedef struct {
  PIndx p;
  Data  value;
  Bool  valid;
} PrfDataWriteReq deriving(Bits, Eq);

typedef struct {
  PIndx p;
  Bool  valid;
} PrfReadySetReq deriving(Bits, Eq);

interface PRF;
  method Data rd1(PIndx p);
  method Data rd2(PIndx p);
  method Data rd3(PIndx p);
  method Data rd4(PIndx p);
  method Data rd5(PIndx p);
  method Data rdDbg(PIndx p);
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
  Vector#(64, Reg#(Data)) dataRegs <- replicateM(mkReg(0));

  Vector#(64, Reg#(Bool)) readyRegs = newVector;
  for (Integer i = 0; i < 64; i = i + 1) begin
    readyRegs[i] <- mkReg(i < 32 ? True : False);
  end

  Wire#(PrfDataWriteReq) commitDataReq <- mkDWire(PrfDataWriteReq{p: 0, value: 0, valid: False});
  Wire#(PrfDataWriteReq) loadDataReq   <- mkDWire(PrfDataWriteReq{p: 0, value: 0, valid: False});
  Wire#(PrfDataWriteReq) aluDataReq    <- mkDWire(PrfDataWriteReq{p: 0, value: 0, valid: False});
  Wire#(PrfDataWriteReq) mulDataReq    <- mkDWire(PrfDataWriteReq{p: 0, value: 0, valid: False});
  Wire#(PrfDataWriteReq) divDataReq    <- mkDWire(PrfDataWriteReq{p: 0, value: 0, valid: False});

  Wire#(PrfReadySetReq) commitReadyReq <- mkDWire(PrfReadySetReq{p: 0, valid: False});
  Wire#(PrfReadySetReq) loadReadyReq   <- mkDWire(PrfReadySetReq{p: 0, valid: False});
  Wire#(PrfReadySetReq) aluReadyReq    <- mkDWire(PrfReadySetReq{p: 0, valid: False});
  Wire#(PrfReadySetReq) mulReadyReq    <- mkDWire(PrfReadySetReq{p: 0, valid: False});
  Wire#(PrfReadySetReq) divReadyReq    <- mkDWire(PrfReadySetReq{p: 0, valid: False});
  Wire#(PrfReadySetReq) clearReadyReq  <- mkDWire(PrfReadySetReq{p: 0, valid: False});

  function Bool dataHit(PrfDataWriteReq req, PIndx p);
    return req.valid && req.p == p;
  endfunction

  function Bool readyHit(PrfReadySetReq req, PIndx p);
    return req.valid && req.p == p;
  endfunction

  function Bool dataReadyMismatch(PrfDataWriteReq dReq, PrfReadySetReq rReq);
    return (dReq.valid != rReq.valid) ||
      (dReq.valid && rReq.valid && dReq.p != rReq.p);
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    for (Integer i = 1; i < 64; i = i + 1) begin
      PIndx p = fromInteger(i);

      Bool loadDataHit   = dataHit(loadDataReq, p);
      Bool aluDataHit    = dataHit(aluDataReq, p);
      Bool mulDataHit    = dataHit(mulDataReq, p);
      Bool divDataHit    = dataHit(divDataReq, p);
      Bool commitDataHit = dataHit(commitDataReq, p);

      Bool loadReadyHit   = readyHit(loadReadyReq, p);
      Bool aluReadyHit    = readyHit(aluReadyReq, p);
      Bool mulReadyHit    = readyHit(mulReadyReq, p);
      Bool divReadyHit    = readyHit(divReadyReq, p);
      Bool commitReadyHit = readyHit(commitReadyReq, p);
      Bool clearHit       = readyHit(clearReadyReq, p);

      Bool anySetHit = loadReadyHit || aluReadyHit || mulReadyHit ||
        divReadyHit || commitReadyHit;

      Bool dataConflict =
        (commitDataHit && (divDataHit || mulDataHit || aluDataHit || loadDataHit)) ||
        (divDataHit    && (mulDataHit || aluDataHit || loadDataHit)) ||
        (mulDataHit    && (aluDataHit || loadDataHit)) ||
        (aluDataHit    && loadDataHit);

      Bool setConflict =
        (commitReadyHit && (divReadyHit || mulReadyHit || aluReadyHit || loadReadyHit)) ||
        (divReadyHit    && (mulReadyHit || aluReadyHit || loadReadyHit)) ||
        (mulReadyHit    && (aluReadyHit || loadReadyHit)) ||
        (aluReadyHit    && loadReadyHit);

`ifdef CONFIG_BSIM
      if (dataConflict) begin
        $display("PRF ERROR: multiple data writes target P%0d in one cycle", p);
        $finish(1);
      end
      if (setConflict) begin
        $display("PRF ERROR: multiple ready sets target P%0d in one cycle", p);
        $finish(1);
      end
      if (clearHit && anySetHit) begin
        $display("PRF ERROR: clearReady and setReady target P%0d in one cycle", p);
        $finish(1);
      end
`endif

      if (commitDataHit) begin
        dataRegs[p] <= commitDataReq.value;
      end else if (divDataHit) begin
        dataRegs[p] <= divDataReq.value;
      end else if (mulDataHit) begin
        dataRegs[p] <= mulDataReq.value;
      end else if (aluDataHit) begin
        dataRegs[p] <= aluDataReq.value;
      end else if (loadDataHit) begin
        dataRegs[p] <= loadDataReq.value;
      end

      if (clearHit) begin
        readyRegs[p] <= False;
      end else if (commitReadyHit) begin
        readyRegs[p] <= True;
      end else if (divReadyHit) begin
        readyRegs[p] <= True;
      end else if (mulReadyHit) begin
        readyRegs[p] <= True;
      end else if (aluReadyHit) begin
        readyRegs[p] <= True;
      end else if (loadReadyHit) begin
        readyRegs[p] <= True;
      end
    end

`ifdef CONFIG_BSIM
    if (dataReadyMismatch(loadDataReq, loadReadyReq)) begin
      $display("PRF ERROR: load data/ready request mismatch");
      $finish(1);
    end
    if (dataReadyMismatch(aluDataReq, aluReadyReq)) begin
      $display("PRF ERROR: ALU data/ready request mismatch");
      $finish(1);
    end
    if (dataReadyMismatch(mulDataReq, mulReadyReq)) begin
      $display("PRF ERROR: mul data/ready request mismatch");
      $finish(1);
    end
    if (dataReadyMismatch(divDataReq, divReadyReq)) begin
      $display("PRF ERROR: div data/ready request mismatch");
      $finish(1);
    end
    if (dataReadyMismatch(commitDataReq, commitReadyReq)) begin
      $display("PRF ERROR: commit data/ready request mismatch");
      $finish(1);
    end
`endif
  endrule

  function Data read(PIndx p) = dataRegs[p];
  method Data rd1(PIndx p) = read(p);
  method Data rd2(PIndx p) = read(p);
  method Data rd3(PIndx p) = read(p);
  method Data rd4(PIndx p) = read(p);
  method Data rd5(PIndx p) = read(p);
  method Data rdDbg(PIndx p) = read(p);
  method Bool isReady (PIndx p) = readyRegs[p];
  method Bool isReady2(PIndx p) = readyRegs[p];

  method Action commitWrite(PIndx p, Data v);
    if (p != 0) commitDataReq <= PrfDataWriteReq{p: p, value: v, valid: True};
  endmethod

  method Action setReadyCommit(PIndx p);
    if (p != 0) commitReadyReq <= PrfReadySetReq{p: p, valid: True};
  endmethod

  method Action clearReady(PIndx p);
    if (p != 0) clearReadyReq <= PrfReadySetReq{p: p, valid: True};
  endmethod

  method Action cdbWriteLoad(PIndx p, Data v);
    if (p != 0) loadDataReq <= PrfDataWriteReq{p: p, value: v, valid: True};
  endmethod

  method Action cdbWriteALU(PIndx p, Data v);
    if (p != 0) aluDataReq <= PrfDataWriteReq{p: p, value: v, valid: True};
  endmethod

  method Action cdbWriteMul(PIndx p, Data v);
    if (p != 0) mulDataReq <= PrfDataWriteReq{p: p, value: v, valid: True};
  endmethod

  method Action cdbWriteDiv(PIndx p, Data v);
    if (p != 0) divDataReq <= PrfDataWriteReq{p: p, value: v, valid: True};
  endmethod

  method Action setReadyLoad(PIndx p);
    if (p != 0) loadReadyReq <= PrfReadySetReq{p: p, valid: True};
  endmethod

  method Action setReadyALU(PIndx p);
    if (p != 0) aluReadyReq <= PrfReadySetReq{p: p, valid: True};
  endmethod

  method Action setReadyMul(PIndx p);
    if (p != 0) mulReadyReq <= PrfReadySetReq{p: p, valid: True};
  endmethod

  method Action setReadyDiv(PIndx p);
    if (p != 0) divReadyReq <= PrfReadySetReq{p: p, valid: True};
  endmethod
endmodule
