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
  method Action checkpoint(RobTag tag); // snapshot for branch recovery
  method Action restore(RobTag tag);    // restore branch snapshot
  method Action clear;               // reset to initial state
  method Action restoreFromRetRAT(Vector#(32, PIndx) ret); // rebuild from retirement RAT
endinterface

module mkFreeList(FreeList);
  Vector#(32, Reg#(PIndx)) data <- replicateM(mkRegU);
  Reg#(Bit#(5)) enqP <- mkReg(0);
  Reg#(Bit#(5)) deqP <- mkReg(0);
  Reg#(Bit#(6)) count <- mkReg(0);
  Reg#(Bool) initialized <- mkReg(False);
  Reg#(Bit#(5)) initIdx <- mkReg(0);

  Vector#(32, Reg#(Vector#(32, PIndx))) checkpoints <- replicateM(mkRegU);
  Vector#(32, Reg#(Bit#(5))) cpEnqP <- replicateM(mkRegU);
  Vector#(32, Reg#(Bit#(5))) cpDeqP <- replicateM(mkRegU);
  Vector#(32, Reg#(Bit#(6))) cpCount <- replicateM(mkRegU);
  Vector#(32, Reg#(Bool)) cpValid <- replicateM(mkReg(False));

  Ehr#(3, Maybe#(PIndx)) enqReq <- mkEhr(tagged Invalid);
  Ehr#(3, Maybe#(Bool)) deqReq <- mkEhr(tagged Invalid);
  Ehr#(2, Maybe#(Bool)) clearReq <- mkEhr(tagged Invalid);
  Ehr#(2, Maybe#(RobTag)) restoreReq <- mkEhr(tagged Invalid);
  Ehr#(2, Maybe#(RobTag)) checkpointReq <- mkEhr(tagged Invalid);
  Ehr#(2, Maybe#(Vector#(32, PIndx))) restoreRetReq <- mkEhr(tagged Invalid);

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
  rule canonicalize (initialized);
    if (isValid(clearReq[1])) begin
      enqP <= 0;
      deqP <= 0;
      count <= 0;
      initialized <= False;
      initIdx <= 0;
      for (Integer i = 0; i < 32; i = i + 1) begin
        cpValid[i] <= False;
      end
    end else if (restoreRetReq[1] matches tagged Valid .ret) begin
      // Rebuild free list as complement of retirement RAT:
      // every physical register not mapped by retRAT is free.
      Vector#(64, Bit#(64)) oneHot = ?;
      for (Integer i = 0; i < 64; i = i + 1) begin
        oneHot[i] = 1 << i;
      end
      Bit#(64) mappedBits = 0;
      for (Integer i = 0; i < 32; i = i + 1) begin
        PIndx idx = ret[i];
        mappedBits = mappedBits | oneHot[idx];
      end
      Bit#(6) freeIdx = 0;
      for (Integer p = 0; p < 64; p = p + 1) begin
        if (mappedBits[p] == 0 && freeIdx < fromInteger(32)) begin
          Bit#(5) dIdx = truncate(freeIdx);
          PIndx pReg = fromInteger(p);
          data[dIdx] <= pReg;
          freeIdx = freeIdx + 1;
        end
      end
      enqP <= 0;
      deqP <= 0;
      count <= freeIdx;
      for (Integer i = 0; i < 32; i = i + 1) begin
        cpValid[i] <= False;
      end
    end else if (restoreReq[1] matches tagged Valid .tag &&& cpValid[tag]) begin
      Vector#(32, PIndx) snap = checkpoints[tag];
      for (Integer i = 0; i < 32; i = i + 1) begin
        data[fromInteger(i)] <= snap[fromInteger(i)];
      end
      enqP <= cpEnqP[tag];
      deqP <= cpDeqP[tag];
      count <= cpCount[tag];
    end else begin
      Bit#(5) nextEnqP = enqP;
      Bit#(5) nextDeqP = deqP;
      Bit#(6) nextCount = count;
      PIndx enqVal = 0;
      Bool hasEnqReq = False;
      Bool enqAlreadyFree = False;

      if (enqReq[2] matches tagged Valid .p) begin
        enqVal = p;
        hasEnqReq = True;
        for (Integer i = 0; i < 32; i = i + 1) begin
          Bit#(6) off = fromInteger(i);
          Bit#(5) idx = deqP + truncate(off);
          if (off < count && data[idx] == p) begin
            enqAlreadyFree = True;
          end
        end
      end

      Bool doRealEnq = hasEnqReq && !enqAlreadyFree;
      if (doRealEnq) begin
        data[enqP] <= enqVal;
        nextEnqP = nextPtr(enqP);
        nextCount = nextCount + 1;
      end
      if (isValid(deqReq[2])) begin
        nextDeqP = nextPtr(deqP);
        nextCount = nextCount - 1;
      end

      if (checkpointReq[1] matches tagged Valid .tag) begin
        Vector#(32, PIndx) snap = ?;
        for (Integer i = 0; i < 32; i = i + 1) begin
          snap[fromInteger(i)] = data[fromInteger(i)];
        end
        if (doRealEnq) begin
          snap[enqP] = enqVal;
        end
        checkpoints[tag] <= snap;
        cpEnqP[tag] <= nextEnqP;
        cpDeqP[tag] <= nextDeqP;
        cpCount[tag] <= nextCount;
        cpValid[tag] <= True;
      end

      enqP <= nextEnqP;
      deqP <= nextDeqP;
      count <= nextCount;
    end

    clearReq[1] <= tagged Invalid;
    restoreReq[1] <= tagged Invalid;
    restoreRetReq[1] <= tagged Invalid;
    checkpointReq[1] <= tagged Invalid;
    enqReq[2] <= tagged Invalid;
    deqReq[2] <= tagged Invalid;
  endrule

  method PIndx first if (initialized && count != 0);
    Bit#(5) firstPtr = isValid(deqReq[2]) ? nextPtr(deqP) : deqP;
    return data[firstPtr];
  endmethod

  method Bool notEmpty = initialized && (count != 0);

  method Bool notFull = initialized && (count != depth);

  method Action deq if (initialized && count != 0);
    deqReq[0] <= tagged Valid True;
  endmethod

  method Action enq(PIndx p) if (initialized && count != depth);
    enqReq[0] <= tagged Valid p;
  endmethod

  method Action checkpoint(RobTag tag) if (initialized);
    checkpointReq[0] <= tagged Valid tag;
  endmethod

  method Action restore(RobTag tag) if (initialized);
    enqReq[1] <= tagged Invalid;
    deqReq[1] <= tagged Invalid;
    checkpointReq[1] <= tagged Invalid;
    restoreReq[0] <= tagged Valid tag;
  endmethod

  method Action clear if (initialized);
    enqReq[1] <= tagged Invalid;
    deqReq[1] <= tagged Invalid;
    restoreReq[0] <= tagged Invalid;
    checkpointReq[1] <= tagged Invalid;
    restoreRetReq[0] <= tagged Invalid;
    clearReq[0] <= tagged Valid True;
  endmethod

  method Action restoreFromRetRAT(Vector#(32, PIndx) ret) if (initialized);
    enqReq[1] <= tagged Invalid;
    deqReq[1] <= tagged Invalid;
    restoreReq[0] <= tagged Invalid;
    checkpointReq[1] <= tagged Invalid;
    restoreRetReq[0] <= tagged Valid ret;
  endmethod
endmodule
