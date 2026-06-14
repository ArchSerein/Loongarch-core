import Types::*;
import ProcTypes::*;
import BranchPredTypes::*;
import Vector::*;

// ============================================================================
// Main BTB — L1 Accurate-Path BTB
// ============================================================================
// Larger capacity BTB that provides CFI type information and target addresses
// to the accurate prediction path (TAGE / ITTAGE).
//
// Responsibilities:
//   1. Record CFI type (branch / jal / jalr / call / ret)
//   2. Record direct target address
//   3. Record indirect jump last-target (ITTAGE miss fallback)
//   4. Optional bias counter for always-taken branches
//   5. Optional confidence counter for target quality
// ============================================================================

interface MBtb;
    // Look up PC in mBTB, returns valid entry or Invalid
    method Maybe#(MBtbEntry) lookup(Addr pc);
    // Get the CFI type for this PC (CFI_NONE if miss)
    method CfiType getCfiType(Addr pc);
    // Get the target for the PC (pc+4 if miss)
    method Addr getTarget(Addr pc);
    // Update entry with resolved control-flow info
    method Action update(Addr pc, CfiType cfi, Addr target);
    // Restore an entry from undo log (commit recovery)
    method Action restore(Bit#(LogMbtbEntries) index, MBtbEntry oldEntry);
    // Read raw entry for undo log capture
    method MBtbEntry getEntry(Bit#(LogMbtbEntries) index);
    // Get index for a PC (needed for undo log)
    method Bit#(LogMbtbEntries) getIndex(Addr pc);
endinterface

module mkMBtb(MBtb);

    Vector#(MbtbEntries, Reg#(MBtbEntry)) entries <-
        replicateM(mkReg(MBtbEntry{
            valid:    False,
            tag:      0,
            cfi_type: CFI_NONE,
            target:   0,
            bias_ctr: 2'b01,    // weak not-taken
            conf:     0
        }));

    // ---- Index and Tag Functions ----
    function Bit#(LogMbtbEntries) computeIndex(Addr pc);
        return truncate(pc >> 2);
    endfunction

    function Bit#(MbtbTagSz) computeTag(Addr pc);
        return truncate(pc >> (2 + valueOf(LogMbtbEntries)));
    endfunction

    // ---- 2-bit Bias Counter ----
    function Bit#(2) updateBiasCtr(Bit#(2) ctr, Bool taken);
        return case (ctr)
            2'b00: (taken ? 2'b01 : 2'b00);
            2'b01: (taken ? 2'b10 : 2'b00);
            2'b10: (taken ? 2'b11 : 2'b01);
            2'b11: (taken ? 2'b11 : 2'b10);
        endcase;
    endfunction

    // ---- 2-bit Confidence Counter ----
    function Bit#(2) updateConf(Bit#(2) conf, Bool correct);
        if (correct)
            return (conf == 2'b11) ? 2'b11 : conf + 1;
        else
            return (conf == 2'b00) ? 2'b00 : conf - 1;
    endfunction

    // ---- Lookup ----
    method Maybe#(MBtbEntry) lookup(Addr pc);
        Bit#(LogMbtbEntries) idx = computeIndex(pc);
        Bit#(MbtbTagSz) tag = computeTag(pc);
        MBtbEntry entry = entries[idx];

        if (entry.valid && (entry.tag == tag))
            return tagged Valid entry;
        else
            return tagged Invalid;
    endmethod

    // ---- Convenience: get CFI type ----
    method CfiType getCfiType(Addr pc);
        Bit#(LogMbtbEntries) idx = computeIndex(pc);
        Bit#(MbtbTagSz) tag = computeTag(pc);
        MBtbEntry entry = entries[idx];

        if (entry.valid && (entry.tag == tag))
            return entry.cfi_type;
        else
            return CFI_NONE;
    endmethod

    // ---- Convenience: get target ----
    method Addr getTarget(Addr pc);
        Bit#(LogMbtbEntries) idx = computeIndex(pc);
        Bit#(MbtbTagSz) tag = computeTag(pc);
        MBtbEntry entry = entries[idx];

        if (entry.valid && (entry.tag == tag))
            return entry.target;
        else
            return pc + 4;
    endmethod

    // ---- Update ----
    method Action update(Addr pc, CfiType cfi, Addr target);
        Bit#(LogMbtbEntries) idx = computeIndex(pc);
        Bit#(MbtbTagSz) tag = computeTag(pc);
        MBtbEntry entry = entries[idx];

        entry.valid    = True;
        entry.tag      = tag;
        entry.cfi_type = cfi;
        entry.target   = target;

        // Update bias counter for conditional branches
        if (cfi == CFI_COND)
            entry.bias_ctr = updateBiasCtr(entry.bias_ctr, True);

        entries[idx] <= entry;
    endmethod

    // ---- Restore from Undo Log ----
    method Action restore(Bit#(LogMbtbEntries) index, MBtbEntry oldEntry);
        entries[index] <= oldEntry;
    endmethod

    // ---- Read Raw Entry ----
    method MBtbEntry getEntry(Bit#(LogMbtbEntries) index);
        return entries[index];
    endmethod

    // ---- Get Index ----
    method Bit#(LogMbtbEntries) getIndex(Addr pc);
        return computeIndex(pc);
    endmethod

endmodule
