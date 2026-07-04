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
endinterface

module mkRAT(RAT);
  // Speculative RAT: maps logical reg -> physical reg (most recent mapping)
  Vector#(32, Reg#(PIndx)) specRAT <- replicateM(mkReg(0));
  // Retirement RAT: maps logical reg -> physical reg (committed state)
  Vector#(32, Reg#(PIndx)) retRAT <- replicateM(mkReg(0));
  // Checkpoint table: full RAT snapshots indexed by ROB tag
  Vector#(32, Reg#(Vector#(32, PIndx))) checkpoints <- replicateM(mkRegU);
  Vector#(32, Reg#(Bool)) cpValid <- replicateM(mkReg(False));

  method PIndx lookup(RIndx r);
    return specRAT[r];
  endmethod

  method PIndx lookupRet(RIndx r);
    return retRAT[r];
  endmethod

  method Action update(RIndx r, PIndx p); 
    if (r != 0) begin
      specRAT[r] <= p;
    end
  endmethod

  method Action updateRet(RIndx r, PIndx p);
    if (r != 0) begin
      retRAT[r] <= p;
    end
  endmethod

  method Action checkpoint(RobTag tag);
    Vector#(32, PIndx) snap = ?;
    for (Integer i = 0; i < 32; i = i + 1) begin
      snap[i] = specRAT[i];
    end
    checkpoints[tag] <= snap;
    cpValid[tag] <= True;
  endmethod

  method Action restore(RobTag tag);
    if (cpValid[tag]) begin
      Vector#(32, PIndx) snap = checkpoints[tag];
      for (Integer i = 0; i < 32; i = i + 1) begin
        specRAT[i] <= snap[i];
      end
    end
  endmethod

  method Action restoreFromRetirement();
    for (Integer i = 0; i < 32; i = i + 1) begin
      specRAT[i] <= retRAT[i];
    end
  endmethod
endmodule
