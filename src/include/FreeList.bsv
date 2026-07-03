import Types::*;
import ProcTypes::*;
import Vector::*;
import Ehr::*;
import OoOTypes::*;

// ============================================================
// Free List: 32-entry FIFO of free physical registers
// Initialized with P32-P63 on startup
// alloc (deq) by RN stage, free (enq) by CM stage
// ============================================================

interface FreeList;
  method PIndx first;                // peek next available PRF
  method Action deq;                 // allocate (RN stage)
  method Action enq(PIndx p);        // free (CM stage)
  method Bool notEmpty;
  method Bool notFull;
  method Action clear;               // reset to initial state
endinterface

module mkFreeList(FreeList);
  Vector#(32, Reg#(PIndx)) data <- replicateM(mkRegU);
  Reg#(Bit#(5)) enqP <- mkReg(0);
  Reg#(Bit#(5)) deqP <- mkReg(0);
  Reg#(Bit#(6)) count <- mkReg(0);
  Reg#(Bool) initialized <- mkReg(False);
  Reg#(Bit#(5)) initIdx <- mkReg(0);

  Ehr#(3, Maybe#(PIndx)) enqReq <- mkEhr(tagged Invalid);
  Ehr#(3, Maybe#(Bool)) deqReq <- mkEhr(tagged Invalid);
  Ehr#(2, Maybe#(Bool)) clearReq <- mkEhr(tagged Invalid);

  Bit#(5) maxIndex = fromInteger(valueOf(32) - 1);
  Bit#(6) depth = fromInteger(valueOf(32));

  function Bit#(5) nextPtr(Bit#(5) ptr);
    return (ptr == maxIndex) ? 0 : ptr + 1;
  endfunction

  // Initialization: load P32-P63 into the free list
  rule doInit (!initialized);
    data[initIdx] <= zeroExtend(initIdx) + 32;
    if (initIdx == maxIndex) begin
      initialized <= True;
      count <= depth;
    end
    else begin
      initIdx <= initIdx + 1;
    end
  endrule

  // Canonicalize: process enq/deq/clear requests
  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize (initialized);
    if (isValid(clearReq[1])) begin
      enqP <= 0;
      deqP <= 0;
      count <= 0;
      initialized <= False;
      initIdx <= 0;
    end else begin
      Bit#(5) nextEnqP = enqP;
      Bit#(5) nextDeqP = deqP;
      Bit#(6) nextCount = count;

      if (enqReq[2] matches tagged Valid .p) begin
        data[enqP] <= p;
        nextEnqP = nextPtr(enqP);
        nextCount = nextCount + 1;
      end
      if (isValid(deqReq[2])) begin
        nextDeqP = nextPtr(deqP);
        nextCount = nextCount - 1;
      end

      enqP <= nextEnqP;
      deqP <= nextDeqP;
      count <= nextCount;
    end

    clearReq[1] <= tagged Invalid;
    enqReq[2] <= tagged Invalid;
    deqReq[2] <= tagged Invalid;
  endrule

  method PIndx first if (initialized && count != 0);
    return data[deqP];
  endmethod

  method Bool notEmpty = initialized && (count != 0);

  method Bool notFull = initialized && (count != depth);

  method Action deq if (initialized && count != 0);
    deqReq[0] <= tagged Valid True;
  endmethod

  method Action enq(PIndx p) if (initialized && count != depth);
    enqReq[0] <= tagged Valid p;
  endmethod

  method Action clear if (initialized);
    enqReq[1] <= tagged Invalid;
    deqReq[1] <= tagged Invalid;
    clearReq[0] <= tagged Valid True;
  endmethod
endmodule
