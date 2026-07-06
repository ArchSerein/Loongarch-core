import Types::*;
import ProcTypes::*;
import Vector::*;
import Ehr::*;
import OoOTypes::*;

// ============================================================
// Register Alias Table (RAT)
// Speculative RAT (RN stage) + Retirement RAT (CM stage)
// + Checkpoint table for branch recovery
//
// specRAT uses EHR so that, within the same rename cycle, update
// (port 1 write) is visible to checkpoint (port 2 read). With
// mkReg the checkpoint would snapshot the PRE-update state,
// causing branch-mispredict recovery to undo the branch's own
// destination mapping — a subtle but fatal bug.
//
// Port allocation:
//   [0] lookup            (read, sees pre-update state)
//   [1] update            (write)
//   [2] checkpoint        (read, sees post-update state)
//   [3] restore           (write, mispredict recovery)
//   [4] restoreFromRetirement (write, exception recovery)
// ============================================================

interface RAT;
  method PIndx lookup(RIndx r);                    // speculative RAT read (RN)
  method PIndx lookupRet(RIndx r);                 // retirement RAT read (CM/debug)
  method Action update(RIndx r, PIndx p);          // speculative RAT update (RN)
  method Action updateRet(RIndx r, PIndx p);       // retirement RAT update (CM)
  method Action checkpoint(RobTag tag);            // snapshot speculative RAT
  method Action restore(RobTag tag);               // restore from checkpoint
  method Action restoreFromRetirement();           // restore specRAT from retRAT
  method Vector#(32, PIndx) allRetRAT;             // full retirement RAT (for free list rebuild)
endinterface

module mkRAT(RAT);
  // Speculative RAT: maps logical reg -> physical reg (most recent mapping)
  // EHR so checkpoint sees the same-cycle update.
  Vector#(32, Ehr#(5, PIndx)) specRAT = newVector;
  for (Integer i = 0; i < 32; i = i + 1) begin
    specRAT[i] <- mkEhr(fromInteger(i));
  end
  // Retirement RAT: maps logical reg -> physical reg (committed state)
  Vector#(32, Reg#(PIndx)) retRAT = newVector;
  for (Integer i = 0; i < 32; i = i + 1) begin
    retRAT[i] <- mkReg(fromInteger(i));
  end
  // Checkpoint table: full RAT snapshots indexed by ROB tag
  Vector#(32, Reg#(Vector#(32, PIndx))) checkpoints <- replicateM(mkRegU);
  Vector#(32, Reg#(Bool)) cpValid <- replicateM(mkReg(False));

  method PIndx lookup(RIndx r);
    return specRAT[r][0];
  endmethod

  method PIndx lookupRet(RIndx r);
    return retRAT[r];
  endmethod

  method Action update(RIndx r, PIndx p);
    if (r != 0) begin
      specRAT[r][1] <= p;
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
      snap[i] = specRAT[i][2];   // sees the same-cycle update (port 1)
    end
    checkpoints[tag] <= snap;
    cpValid[tag] <= True;
  endmethod

  method Action restore(RobTag tag);
    if (cpValid[tag]) begin
      Vector#(32, PIndx) snap = checkpoints[tag];
      for (Integer i = 0; i < 32; i = i + 1) begin
        specRAT[i][3] <= snap[i];
      end
    end
  endmethod

  method Action restoreFromRetirement();
    for (Integer i = 0; i < 32; i = i + 1) begin
      specRAT[i][4] <= retRAT[i];
    end
  endmethod

  method Vector#(32, PIndx) allRetRAT;
    Vector#(32, PIndx) ret = ?;
    for (Integer i = 0; i < 32; i = i + 1) begin
      ret[i] = retRAT[i];
    end
    return ret;
  endmethod
endmodule
