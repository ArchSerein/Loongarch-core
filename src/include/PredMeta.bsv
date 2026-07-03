import Types::*;
import ProcTypes::*;
import BranchPredTypes::*;
import Vector::*;

// ============================================================================
// Prediction Meta Queue & Undo Log
// ============================================================================
//
// PredictionQueue:  Tracks in-flight branch prediction metadata.
//   Carried through the pipeline to provide context for execute-stage training
//   and commit-stage recovery. Supports PC-based lookup.
//
// UndoLog:  Records pre-modification predictor values.
//   Execute-stage speculative writes push undo entries; commit confirms or
//   rolls back via head/tail pointer management.
// ============================================================================

// ---- Prediction Queue Parameters ----
typedef 6  LogPredQEntries;   // 64-entry prediction queue
typedef TExp#(LogPredQEntries) PredQEntries;
typedef Bit#(LogPredQEntries) PredQPtr;

// ---- Prediction Queue ----
interface PredictionQueue;
    // Enqueue prediction metadata for an in-flight branch
    method Action enq(PredMeta meta);
    // Look up prediction meta by PC (for execute-stage correlation)
    method Maybe#(PredMeta) lookup(Addr pc);
    // Dequeue and clear entry by PC (called at commit)
    method Action deq(Addr pc);
    // Clear all entries (pipeline flush)
    method Action clear();
    // Check if queue has free slots
    method Bool notFull();
endinterface

module mkPredictionQueue(PredictionQueue);

    // Entry: valid bit + PredMeta
    Vector#(PredQEntries, Reg#(Bool)) valid <-
        replicateM(mkReg(False));
    Vector#(PredQEntries, Reg#(PredMeta)) entries <-
        replicateM(mkRegU);

    // Allocate pointer (next free slot, increments on enq)
    Reg#(PredQPtr) allocPtr <- mkReg(0);

    // Find the next free slot
    function PredQPtr findFreeSlot();
        PredQPtr ptr = 0;
        for (Integer i = 0; i < valueOf(PredQEntries); i = i + 1) begin
            if (!valid[i]) begin
                ptr = fromInteger(i);
            end
        end
        return ptr;
    endfunction

    method Action enq(PredMeta meta);
        PredQPtr ptr = findFreeSlot();
        valid[ptr]   <= True;
        entries[ptr] <= meta;
    endmethod

    method Maybe#(PredMeta) lookup(Addr pc);
        // Search all valid entries for PC match, return the last match found
        // (which is the most recently enqueued entry for this PC)
        Maybe#(PredMeta) result = tagged Invalid;
        for (Integer i = 0; i < valueOf(PredQEntries); i = i + 1) begin
            if (valid[i] && entries[i].pc == pc)
                result = tagged Valid entries[i];
        end
        return result;
    endmethod

    method Action deq(Addr pc);
        for (Integer i = 0; i < valueOf(PredQEntries); i = i + 1) begin
            if (valid[i] && entries[i].pc == pc)
                valid[i] <= False;
        end
    endmethod

    method Action clear();
        for (Integer i = 0; i < valueOf(PredQEntries); i = i + 1)
            valid[i] <= False;
    endmethod

    method Bool notFull();
        Bool result = False;
        for (Integer i = 0; i < valueOf(PredQEntries); i = i + 1) begin
            if (!valid[i])
                result = True;
        end
        return result;
    endmethod

endmodule

// ---- Undo Log ----
interface UndoLog;
    // Push an undo entry (records pre-modification value)
    // Returns the new tail pointer for later recovery
    method Action push(PredictorUndoEntry entry);
    // Get current tail pointer (use as undo_begin before speculative writes)
    method UndoLogPtr getTail();
    // Discard entries from head to newHead (commit confirmation)
    method Action commit(UndoLogPtr newHead);
    // Pop the last entry (caller handles restore logic)
    method Action pop();
    method Maybe#(PredictorUndoEntry) last();
    // Read entry at specific index
    method PredictorUndoEntry read(UndoLogPtr index);
    // Reset the undo log
    method Action reset();
endinterface

module mkUndoLog(UndoLog);

    Vector#(UndoLogSize, Reg#(PredictorUndoEntry)) entries <-
        replicateM(mkRegU);

    // Head: oldest committed entry (behind this = freed)
    // Tail: next free slot (entries from head to tail-1 are in-flight)
    Reg#(UndoLogPtr) head <- mkReg(0);
    Reg#(UndoLogPtr) tail <- mkReg(0);

    method Action push(PredictorUndoEntry entry);
        entries[tail] <= entry;
        tail <= tail + 1;
    endmethod

    method UndoLogPtr getTail();
        return tail;
    endmethod

    method Action commit(UndoLogPtr newHead);
        head <= newHead;
    endmethod

    method Action pop();
        tail <= tail - 1;
    endmethod

    method Maybe#(PredictorUndoEntry) last();
        Maybe#(PredictorUndoEntry) result = tagged Invalid;
        if (tail != head) begin
            UndoLogPtr prev = tail - 1;
            result = tagged Valid entries[prev];
        end
        return result;
    endmethod

    method PredictorUndoEntry read(UndoLogPtr index);
        return entries[index];
    endmethod

    method Action reset();
        head <= 0;
        tail <= 0;
    endmethod

endmodule
