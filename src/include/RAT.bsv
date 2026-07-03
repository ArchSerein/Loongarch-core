import Types::*;
import ProcTypes::*;
import Vector::*;
import OoOTypes::*;

// ============================================================
// Register Alias Table (RAT)
// Speculative RAT (RN stage) + Retirement RAT (CM stage)
// + Checkpoint table for branch recovery
// ============================================================

interface RAT;
  method PIndx lookup(RIndx r);                    // speculative RAT read (RN)
  method PIndx lookupRet(RIndx r);                 // retirement RAT read (CM/debug)
  method Action update(RIndx r, PIndx p);          // speculative RAT update (RN)
  method Action updateRet(RIndx r, PIndx p);       // retirement RAT update (CM)
  method Action checkpoint(RobTag tag);            // snapshot speculative RAT
  method Action restore(RobTag tag);               // restore from checkpoint
  method Action restoreFromRetirement();           // restore specRAT from retRAT
  method Action clear;                             // reset to initial state
endinterface

module mkRAT(RAT);
  // Speculative RAT: maps logical reg -> physical reg (most recent mapping)
  Vector#(32, Reg#(PIndx)) specRAT <- replicateM(mkRegU);
  // Retirement RAT: maps logical reg -> physical reg (committed state)
  Vector#(32, Reg#(PIndx)) retRAT <- replicateM(mkRegU);
  // Checkpoint table: full RAT snapshots indexed by ROB tag
  Vector#(32, Reg#(Vector#(32, PIndx))) checkpoints <- replicateM(mkRegU);
  Vector#(32, Reg#(Bool)) cpValid <- replicateM(mkReg(False));

  Reg#(Bool) initialized <- mkReg(False);
  Reg#(Bit#(5)) initIdx <- mkReg(0);

  // Initialization: R0-R31 -> P0-P31 in both RATs
  rule doInit (!initialized);
    specRAT[initIdx] <= zeroExtend(initIdx);
    retRAT[initIdx] <= zeroExtend(initIdx);
    if (initIdx == 31) initialized <= True;
    else initIdx <= initIdx + 1;
  endrule

  method PIndx lookup(RIndx r) if (initialized);
    return specRAT[r];
  endmethod

  method PIndx lookupRet(RIndx r) if (initialized);
    return retRAT[r];
  endmethod

  method Action update(RIndx r, PIndx p) if (initialized);
    if (r != 0) begin
      specRAT[r] <= p;
    end
  endmethod

  method Action updateRet(RIndx r, PIndx p) if (initialized);
    if (r != 0) begin
      retRAT[r] <= p;
    end
  endmethod

  method Action checkpoint(RobTag tag) if (initialized);
    Vector#(32, PIndx) snap = ?;
    for (Integer i = 0; i < 32; i = i + 1) begin
      snap[i] = specRAT[i];
    end
    checkpoints[tag] <= snap;
    cpValid[tag] <= True;
  endmethod

  method Action restore(RobTag tag) if (initialized);
    if (cpValid[tag]) begin
      Vector#(32, PIndx) snap = checkpoints[tag];
      for (Integer i = 0; i < 32; i = i + 1) begin
        specRAT[i] <= snap[i];
      end
    end
  endmethod

  method Action restoreFromRetirement() if (initialized);
    for (Integer i = 0; i < 32; i = i + 1) begin
      specRAT[i] <= retRAT[i];
    end
  endmethod

  method Action clear if (initialized);
    for (Integer i = 0; i < 32; i = i + 1) begin
      cpValid[i] <= False;
    end
    initialized <= False;
    initIdx <= 0;
  endmethod
endmodule
