import Types::*;
import ProcTypes::*;
import BranchPredTypes::*;
import Vector::*;

// ============================================================================
// Small BTB — L0 Fast-Path Predictor
// ============================================================================
// 1-cycle lookup, small direct-mapped BTB with 2-bit direction counter.
// Provides fast next-PC generation for the front-end.
//
// Entry structure:
//   valid | partial-tag | target | cfi_type | 2-bit-ctr
//
// Prediction logic:
//   miss                          -> next_pc = pc + 4
//   hit && CFI_COND               -> ctr[1] ? target : pc + 4
//   hit && (JAL || CALL)          -> target
//   hit && (JALR || ICALL || RET) -> target (fallback)
//   hit && CFI_NONE               -> pc + 4
// ============================================================================

interface SmallBtb;
    // Fast-path prediction: returns next-PC info in 1 cycle
    method FastPredInfo predict(Addr pc);
    // Compute the next PC (combines prediction with fallthrough logic)
    method Addr nextPc(Addr pc);
    // Update entry with resolved control-flow info
    method Action update(Addr pc, CfiType cfi, Addr target, Bool taken);
    // Restore an entry from undo log (commit recovery)
    method Action restore(Bit#(LogSmallBtbEntries) index, SmallBtbEntry oldEntry);
    // Read raw entry for undo log capture
    method SmallBtbEntry getEntry(Bit#(LogSmallBtbEntries) index);
endinterface

module mkSmallBtb(SmallBtb);

    Vector#(SmallBtbEntries, Reg#(SmallBtbEntry)) entries <-
        replicateM(mkReg(SmallBtbEntry{
            valid:    False,
            tag:      0,
            target:   0,
            cfi_type: CFI_NONE,
            ctr:      2'b01   // weak not-taken
        }));

    // ---- Index and Tag Functions ----
    function Bit#(LogSmallBtbEntries) getIndex(Addr pc);
        return truncate(pc >> 2);
    endfunction

    function Bit#(SmallBtbTagSz) getTag(Addr pc);
        return truncate(pc >> (2 + valueOf(LogSmallBtbEntries)));
    endfunction

    // ---- 2-bit Counter Update ----
    function Bit#(2) updateCtr(Bit#(2) ctr, Bool taken);
        return case (ctr)
            2'b00: (taken ? 2'b01 : 2'b00);
            2'b01: (taken ? 2'b10 : 2'b00);
            2'b10: (taken ? 2'b11 : 2'b01);
            2'b11: (taken ? 2'b11 : 2'b10);
        endcase;
    endfunction

    // ---- Fast Prediction Lookup ----
    method FastPredInfo predict(Addr pc);
        Bit#(LogSmallBtbEntries) idx = getIndex(pc);
        Bit#(SmallBtbTagSz) tag = getTag(pc);
        SmallBtbEntry entry = entries[idx];
        FastPredInfo result;

        if (entry.valid && (entry.tag == tag)) begin
            result = FastPredInfo{
                valid:    True,
                taken:    (entry.ctr[1] == 1'b1),
                target:   entry.target,
                cfi_type: entry.cfi_type
            };
        end else begin
            result = FastPredInfo{
                valid:    False,
                taken:    False,
                target:   pc + 4,
                cfi_type: CFI_NONE
            };
        end

        return result;
    endmethod

    // ---- Fast Next PC Calculation ----
    method Addr nextPc(Addr pc);
        Bit#(LogSmallBtbEntries) idx = getIndex(pc);
        Bit#(SmallBtbTagSz) tag = getTag(pc);
        SmallBtbEntry entry = entries[idx];
        Addr result = pc + 4;

        if (entry.valid && (entry.tag == tag)) begin
            case (entry.cfi_type)
                CFI_COND:
                    result = (entry.ctr[1] == 1'b1) ? entry.target : (pc + 4);
                CFI_JAL, CFI_CALL:
                    result = entry.target;
                CFI_JALR, CFI_ICALL, CFI_RET:
                    result = entry.target;
            endcase
        end

        return result;
    endmethod

    // ---- Update Entry ----
    method Action update(Addr pc, CfiType cfi, Addr target, Bool taken);
        Bit#(LogSmallBtbEntries) idx = getIndex(pc);
        Bit#(SmallBtbTagSz) tag = getTag(pc);
        SmallBtbEntry entry = entries[idx];
        Bool sameEntry = entry.valid && (entry.tag == tag);

        entry.valid    = True;
        entry.tag      = tag;
        entry.target   = target;
        entry.cfi_type = cfi;

        if (cfi == CFI_COND) begin
            // A tag replacement must not inherit an unrelated branch's
            // direction counter.  Start from weak-not-taken and train once.
            Bit#(2) oldCtr = sameEntry ? entry.ctr : 2'b01;
            entry.ctr = updateCtr(oldCtr, taken);
        end else if (!sameEntry) begin
            entry.ctr = 2'b01;
        end

        entries[idx] <= entry;
    endmethod

    // ---- Restore from Undo Log ----
    method Action restore(Bit#(LogSmallBtbEntries) index, SmallBtbEntry oldEntry);
        entries[index] <= oldEntry;
    endmethod

    // ---- Read Raw Entry ----
    method SmallBtbEntry getEntry(Bit#(LogSmallBtbEntries) index);
        return entries[index];
    endmethod

endmodule
