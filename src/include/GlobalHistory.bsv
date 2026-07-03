import Types::*;
import BranchPredTypes::*;

// ============================================================================
// Global History Manager
// ============================================================================
// Manages two history registers shared across predictors:
//
//   1. Global History Register (GHR):
//      Records branch directions (Taken=1, Not-Taken=0) of recent branches.
//      Used by TAGE direction predictor for table indexing.
//
//   2. Path History Register:
//      Records low-order bits of resolved indirect branch targets.
//      Used by ITTAGE target predictor for table indexing.
//      Captures execution flow (which function was called, etc.).
//
// Both registers support snapshot/restore for checkpoint recovery.
// ============================================================================

interface GlobalHistory;
    // ---- GHR access ----
    method Bit#(GhrSz) ghr();
    method Action updateGhr(Bool taken);

    // ---- Path History access ----
    method Bit#(IttagePathHistSz) pathHist();
    method Action updatePathHist(Addr target);

    // ---- Checkpoint support ----
    method HistSnapshot snapshot();
    method Action restore(HistSnapshot snap);

    // ---- Reset ----
    method Action reset();
endinterface

module mkGlobalHistory(GlobalHistory);

    // Global History Register (branch directions)
    Reg#(Bit#(GhrSz)) ghrReg <- mkReg(0);

    // Path History Register (indirect target hashes)
    Reg#(Bit#(IttagePathHistSz)) pathHistReg <- mkReg(0);

    // ---- Helper: hash target address into 8 bits for path history ----
    function Bit#(8) hashTarget(Addr target);
        // XOR adjacent bytes for a simple uniform hash
        return target[7:0] ^ target[15:8];
    endfunction

    // ---- GHR ----
    method Bit#(GhrSz) ghr();
        return ghrReg;
    endmethod

    method Action updateGhr(Bool taken);
        // Shift left, insert branch outcome at LSB
        ghrReg <= {ghrReg[valueOf(GhrSz)-2 : 0], pack(taken)};
    endmethod

    // ---- Path History ----
    method Bit#(IttagePathHistSz) pathHist();
        return pathHistReg;
    endmethod

    method Action updatePathHist(Addr target);
        // Shift left, insert target hash at LSB
        Bit#(8) th = hashTarget(target);
        pathHistReg <= {pathHistReg[valueOf(IttagePathHistSz)-9 : 0], th};
    endmethod

    // ---- Checkpoint ----
    method HistSnapshot snapshot();
        return HistSnapshot{
            ghist_snapshot: ghrReg,
            phist_snapshot: pathHistReg
        };
    endmethod

    method Action restore(HistSnapshot snap);
        ghrReg      <= snap.ghist_snapshot;
        pathHistReg <= snap.phist_snapshot;
    endmethod

    // ---- Reset ----
    method Action reset();
        ghrReg      <= 0;
        pathHistReg <= 0;
    endmethod

endmodule
