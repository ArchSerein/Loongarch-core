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
  method ActionValue#(PIndx) alloc;  // allocate (RN stage)
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
  Reg#(Bit#(64)) freeMask <- mkReg(0);
  Reg#(Bool) initialized <- mkReg(False);
  Reg#(Bit#(5)) initIdx <- mkReg(0);

  Reg#(Bool) restoreRetBusy <- mkReg(False);
  Reg#(Bit#(7)) restoreRetP <- mkReg(0);
  Reg#(Bit#(6)) restoreRetFreeIdx <- mkReg(0);
  Reg#(Bit#(64)) restoreRetMappedBits <- mkReg(0);
  Reg#(Bit#(64)) restoreRetFreeMask <- mkReg(0);

  Vector#(32, Reg#(Vector#(32, PIndx))) checkpoints <- replicateM(mkRegU);
  Vector#(32, Reg#(Bit#(5))) cpEnqP <- replicateM(mkRegU);
  Vector#(32, Reg#(Bit#(5))) cpDeqP <- replicateM(mkRegU);
  Vector#(32, Reg#(Bit#(6))) cpCount <- replicateM(mkRegU);
  Vector#(32, Reg#(Bit#(64))) cpFreeMask <- replicateM(mkRegU);
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
      freeMask <= 64'hffffffff00000000;
    end
    else begin
      initIdx <= initIdx + 1;
    end
  endrule

  rule canonicalizeClear (initialized && isValid(clearReq[1]));
    enqP <= 0;
    deqP <= 0;
    count <= 0;
    initialized <= False;
    freeMask <= 0;
    initIdx <= 0;
    restoreRetBusy <= False;
    restoreRetP <= 0;
    restoreRetFreeIdx <= 0;
    restoreRetMappedBits <= 0;
    restoreRetFreeMask <= 0;
    for (Integer i = 0; i < 32; i = i + 1) begin
      cpValid[i] <= False;
    end

    clearReq[1] <= tagged Invalid;
    restoreReq[1] <= tagged Invalid;
    restoreRetReq[1] <= tagged Invalid;
    checkpointReq[1] <= tagged Invalid;
    enqReq[2] <= tagged Invalid;
    deqReq[2] <= tagged Invalid;
  endrule

  rule canonicalizeRestoreRetStart (initialized && !restoreRetBusy && !isValid(clearReq[1]) && isValid(restoreRetReq[1]));
    let ret = fromMaybe(?, restoreRetReq[1]);
    Bit#(64) mappedBits = 0;
    for (Integer i = 0; i < 32; i = i + 1) begin
      PIndx idx = ret[i];
      mappedBits[idx] = 1'b1;
    end

    enqP <= 0;
    deqP <= 0;
    count <= 0;
    freeMask <= 0;
    restoreRetBusy <= True;
    restoreRetP <= 0;
    restoreRetFreeIdx <= 0;
    restoreRetMappedBits <= mappedBits;
    restoreRetFreeMask <= 0;
    for (Integer i = 0; i < 32; i = i + 1) begin
      cpValid[i] <= False;
    end

    clearReq[1] <= tagged Invalid;
    restoreReq[1] <= tagged Invalid;
    restoreRetReq[1] <= tagged Invalid;
    checkpointReq[1] <= tagged Invalid;
    enqReq[2] <= tagged Invalid;
    deqReq[2] <= tagged Invalid;
  endrule

  rule canonicalizeRestoreRetStep (initialized && restoreRetBusy && !isValid(clearReq[1]));
    PIndx pReg = truncate(restoreRetP);
    Bit#(6) nextFreeIdx = restoreRetFreeIdx;
    Bit#(64) nextFreeMask = restoreRetFreeMask;

    if (restoreRetMappedBits[pReg] == 0 && restoreRetFreeIdx < depth) begin
      Bit#(5) dIdx = truncate(restoreRetFreeIdx);
      data[dIdx] <= pReg;
      nextFreeIdx = restoreRetFreeIdx + 1;
      nextFreeMask[pReg] = 1'b1;
    end

    if (restoreRetP == 63) begin
      count <= nextFreeIdx;
      freeMask <= nextFreeMask;
      restoreRetBusy <= False;
    end else begin
      restoreRetP <= restoreRetP + 1;
      restoreRetFreeIdx <= nextFreeIdx;
      restoreRetFreeMask <= nextFreeMask;
    end
  endrule

  rule canonicalizeRestore (initialized && !restoreRetBusy && !isValid(clearReq[1]) && !isValid(restoreRetReq[1]) && isValid(restoreReq[1]) && cpValid[fromMaybe(?, restoreReq[1])]);
    let tag = fromMaybe(?, restoreReq[1]);
    Vector#(32, PIndx) snap = checkpoints[tag];
    for (Integer i = 0; i < 32; i = i + 1) begin
      data[fromInteger(i)] <= snap[fromInteger(i)];
    end
    enqP <= cpEnqP[tag];
    deqP <= cpDeqP[tag];
    count <= cpCount[tag];
    freeMask <= cpFreeMask[tag];

    clearReq[1] <= tagged Invalid;
    restoreReq[1] <= tagged Invalid;
    restoreRetReq[1] <= tagged Invalid;
    checkpointReq[1] <= tagged Invalid;
    enqReq[2] <= tagged Invalid;
    deqReq[2] <= tagged Invalid;
  endrule

  rule canonicalizeRestoreInvalid (initialized && !restoreRetBusy && !isValid(clearReq[1]) && !isValid(restoreRetReq[1]) && isValid(restoreReq[1]) && !cpValid[fromMaybe(?, restoreReq[1])]);
    clearReq[1] <= tagged Invalid;
    restoreReq[1] <= tagged Invalid;
    restoreRetReq[1] <= tagged Invalid;
    checkpointReq[1] <= tagged Invalid;
    enqReq[2] <= tagged Invalid;
    deqReq[2] <= tagged Invalid;
  endrule

  rule canonicalizeNormal (initialized && !restoreRetBusy && !isValid(clearReq[1]) && !isValid(restoreRetReq[1]) && !isValid(restoreReq[1]));
    Bit#(5) nextEnqP = enqP;
    Bit#(5) nextDeqP = deqP;
    Bit#(6) nextCount = count;
    Bit#(64) nextFreeMask = freeMask;
    PIndx enqVal = 0;
    Bool hasEnqReq = False;
    Bool enqAlreadyFree = False;

    if (enqReq[2] matches tagged Valid .p) begin
      enqVal = p;
      hasEnqReq = True;
      enqAlreadyFree = unpack(freeMask[p]);
    end

    Bool doRealEnq = hasEnqReq && !enqAlreadyFree;
    if (doRealEnq) begin
      data[enqP] <= enqVal;
      nextEnqP = nextPtr(enqP);
      nextCount = nextCount + 1;
      nextFreeMask[enqVal] = 1'b1;
    end
    if (isValid(deqReq[2])) begin
      PIndx allocVal = data[deqP];
      nextFreeMask[allocVal] = 1'b0;
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
      cpFreeMask[tag] <= nextFreeMask;
      cpValid[tag] <= True;
    end

    enqP <= nextEnqP;
    deqP <= nextDeqP;
    count <= nextCount;
    freeMask <= nextFreeMask;

    clearReq[1] <= tagged Invalid;
    restoreReq[1] <= tagged Invalid;
    restoreRetReq[1] <= tagged Invalid;
    checkpointReq[1] <= tagged Invalid;
    enqReq[2] <= tagged Invalid;
    deqReq[2] <= tagged Invalid;
  endrule

  method Bool notEmpty = initialized && !restoreRetBusy && (count != 0);

  method Bool notFull = initialized && !restoreRetBusy && (count != depth);

  method ActionValue#(PIndx) alloc if (initialized && !restoreRetBusy && count != 0);
    let ret = data[deqP];
    deqReq[0] <= tagged Valid True;
    return ret;
  endmethod

  method Action enq(PIndx p) if (initialized && !restoreRetBusy && count != depth);
    enqReq[0] <= tagged Valid p;
  endmethod

  method Action checkpoint(RobTag tag) if (initialized && !restoreRetBusy);
    checkpointReq[0] <= tagged Valid tag;
  endmethod

  method Action restore(RobTag tag) if (initialized && !restoreRetBusy);
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

  method Action restoreFromRetRAT(Vector#(32, PIndx) ret) if (initialized && !restoreRetBusy);
    enqReq[1] <= tagged Invalid;
    deqReq[1] <= tagged Invalid;
    restoreReq[0] <= tagged Invalid;
    checkpointReq[1] <= tagged Invalid;
    restoreRetReq[0] <= tagged Valid ret;
  endmethod
endmodule
