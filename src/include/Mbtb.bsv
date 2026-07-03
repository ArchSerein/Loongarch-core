import Types::*;
import ProcTypes::*;
import BranchPredTypes::*;
import BpuSRAM::*;
import Vector::*;

// ============================================================================
// Main BTB — L1 Accurate-Path BTB (SRAM-backed)
// ============================================================================
// Larger capacity BTB that provides CFI type information and target addresses
// to the accurate prediction path (TAGE / ITTAGE).
//
// Storage is provided by a single sram_128x64_wrap instance (via BpuSram64):
//   - FPGA: BVI SRAM IP (1-cycle read latency)
//   - Sim:  RegFile + output register (identical 1-cycle latency)
// The 56-bit MBtbEntry is packed into the low bits of the 64-bit SRAM word.
//
// Because the SRAM has 1-cycle read latency, lookup is split into:
//   startLookup(pc)   — cycle N:   issue SRAM read at computeIndex(pc)
//   lookupResult(pc)  — cycle N+1: read SRAM output, compare tag (pc must
//                                  match the one passed to startLookup)
//
// update() is a pure write (bias_ctr/conf are unused in prediction, so they
// are written to fixed defaults; no SRAM read is needed, keeping update at
// 1 cycle so the working execute-stage path stays fast).
// ============================================================================

interface MBtb;
    // Issue a lookup request (cycle N).
    method Action startLookup(Addr pc);
    // Return the result of the lookup issued last cycle. The caller must pass
    // the same pc used in startLookup so the tag can be recomputed and
    // compared against the stored entry's tag.
    method Maybe#(MBtbEntry) lookupResult(Addr pc);
    // Update entry with resolved control-flow info (pure write, 1 cycle).
    method Action update(Addr pc, CfiType cfi, Addr target);
    // Restore an entry from undo log (write, 1 cycle).
    method Action restore(Bit#(LogMbtbEntries) index, MBtbEntry oldEntry);
    // Get index for a PC (combinational, no SRAM access).
    method Bit#(LogMbtbEntries) getIndex(Addr pc);
endinterface

module mkMBtb(MBtb);

    BpuSram64 sram <- mkBpuSram64;

    // ---- Index and Tag Functions ----
    function Bit#(LogMbtbEntries) computeIndex(Addr pc);
        return truncate(pc >> 2);
    endfunction

    function Bit#(MbtbTagSz) computeTag(Addr pc);
        return truncate(pc >> (2 + valueOf(LogMbtbEntries)));
    endfunction

    // ---- Pack / Unpack helpers (56-bit entry <-> 64-bit SRAM word) ----
    function Bit#(64) packMbtbWord(MBtbEntry e);
        return zeroExtend(pack(e));
    endfunction

    function MBtbEntry unpackMbtbWord(Bit#(64) w);
        return unpack(truncate(w));
    endfunction

    // Zero-extend a table index to the 7-bit SRAM address.
    function Bit#(7) padAddr(Bit#(LogMbtbEntries) idx);
        return zeroExtend(idx);
    endfunction

    // ---- Issue lookup ----
    method Action startLookup(Addr pc);
        Bit#(LogMbtbEntries) idx = computeIndex(pc);
        sram.put(8'h00, padAddr(idx), 0);   // wea=0: read
    endmethod

    // ---- Return lookup result (tag compare on registered output) ----
    method Maybe#(MBtbEntry) lookupResult(Addr pc);
        MBtbEntry entry = unpackMbtbWord(sram.read);
        Bit#(MbtbTagSz) tag = computeTag(pc);
        if (entry.valid && (entry.tag == tag))
            return tagged Valid entry;
        else
            return tagged Invalid;
    endmethod

    // ---- Update (pure write) ----
    method Action update(Addr pc, CfiType cfi, Addr target);
        Bit#(LogMbtbEntries) idx = computeIndex(pc);
        Bit#(MbtbTagSz)      tag = computeTag(pc);
        MBtbEntry newEntry = MBtbEntry{
            valid:    True,
            tag:      tag,
            cfi_type: cfi,
            target:   target,
            // bias_ctr/conf are not consumed by the prediction logic; write
            // neutral defaults so the entry is self-contained without reading
            // the old value (keeps update at 1 cycle for the SRAM backend).
            bias_ctr: 2'b01,
            conf:     0
        };
        sram.put(8'hFF, padAddr(idx), packMbtbWord(newEntry));
    endmethod

    // ---- Restore (write) from undo log ----
    method Action restore(Bit#(LogMbtbEntries) index, MBtbEntry oldEntry);
        sram.put(8'hFF, padAddr(index), packMbtbWord(oldEntry));
    endmethod

    // ---- Index (combinational) ----
    method Bit#(LogMbtbEntries) getIndex(Addr pc);
        return computeIndex(pc);
    endmethod

endmodule
