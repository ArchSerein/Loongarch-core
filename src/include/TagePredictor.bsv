import Types::*;
import ProcTypes::*;
import BranchPredTypes::*;
import BpuSRAM::*;
import Vector::*;

// ============================================================================
// TAGE (TAgged GEometric) Direction Predictor (SRAM-backed)
// ============================================================================
// Architecture:
//   Base bimodal table (T0): 16 entries, 2-bit counter (flip-flop — too small
//                            to justify an SRAM instance)
//   Tagged tables (T1-T7):   64 entries each (CONFIG_TAGE_ENTRIES), stored in
//                            one sram_128x64_wrap instance per table (7 total)
//                            {tag(8), signed-ctr(3), usefulness(2)} = 13 bits
//                            packed into the low bits of the 64-bit SRAM word.
//   History lengths: 4, 8, 16, 32, 64, 128, 256 (geometric progression)
//
// SRAM 1-cycle read latency forces the predict path to be split:
//   startPredict(pc, ghr)  — cycle N:   compute 7 indices/tags, issue 7 reads,
//                                       latch pc+ghr for the result cycle
//   predictResult()        — cycle N+1: read 7 SRAM outputs, compare tags,
//                                       pick provider/alternate, return result
//
// update() is a 2-cycle state machine because it must read the current
// provider/alternate entries (to update counters / usefulness / allocation)
// before writing them back:
//   Idle  — update() accepted: latch inputs, issue 7 reads, -> Read
//   Read  — SRAM outputs ready: re-derive provider/alt, compute the final
//           provider entry (new ctr + new usefulness, written once), issue
//           any allocation / usefulness-decrement writes, -> Idle
// During the SM, startPredict is blocked (guarded by state==Idle).
//
// usefulBitAging is simplified to an epoch toggle (no full-table scan, which
// would require a multi-cycle SRAM traversal).
//
// Metadata (TageMeta, 16 bits) — repacked for 64-entry tables:
//   [15:13] provider_table  (0=bimodal, 1-7=T1-T7)
//   [12:10] alternate_table (0=none/bimodal)
//   [9:4]   provider_index  (6 bits)
//   [3:0]   bimodal_index   (4 bits)
// ============================================================================

// ---- TageMeta Packing Helpers ----
function TageMeta packTageMeta(
    Bit#(3) prov_table,
    Bit#(3) alt_table,
    Bit#(LogTageEntries) prov_idx,
    Bit#(4) bimodal_idx
);
    return {prov_table, alt_table, prov_idx, bimodal_idx};
endfunction

function Bit#(3) unpackProvTable(TageMeta meta);
    return meta[15:13];
endfunction

function Bit#(3) unpackAltTable(TageMeta meta);
    return meta[12:10];
endfunction

function Bit#(LogTageEntries) unpackProvIndex(TageMeta meta);
    return meta[9:4];
endfunction

function Bit#(4) unpackBimodalIndex(TageMeta meta);
    return meta[3:0];
endfunction

// ---- Pack / unpack a TAGE entry into a 64-bit SRAM word ----
function Bit#(64) packTageWord(TageEntry e);
    return zeroExtend(pack(e));
endfunction

function TageEntry unpackTageWord(Bit#(64) w);
    return unpack(truncate(w));
endfunction

// Zero-extend a per-table index to the 7-bit SRAM address.
function Bit#(7) padTageAddr(Bit#(LogTageEntries) idx);
    return zeroExtend(idx);
endfunction

// ---- Update state machine ----
typedef enum { TageIdle, TageRead } TageUpdState deriving (Bits, Eq);

// ---- Module Interface ----

interface TagePredictor;
    // Predict branch direction. Split for SRAM latency:
    method Action startPredict(Addr pc, Bit#(GhrSz) ghr);
    method TagePredInfo predictResult();

    // Update predictor state. 2-cycle internal SM; guarded by idle.
    method Action update(Addr pc, Bool taken, Bool mispredict, Bit#(GhrSz) ghr);

    // Restore a TAGE tagged-table entry (write, 1 cycle).
    method Action restoreEntry(
        Bit#(3) table_id,         // 0-6 for T1-T7
        Bit#(LogTageEntries) index,
        TageEntry oldEntry
    );

    // Restore bimodal table entry (write, 1 cycle).
    method Action restoreBimodal(Bit#(4) index, Bit#(2) oldCtr);

    // Periodic useful-bit aging (epoch toggle only).
    method Action usefulBitAging();
endinterface

// ---- Module Implementation ----

module mkTagePredictor(TagePredictor);

    // ---- Base Bimodal Predictor Table (T0) — flip-flop ----
    Vector#(TExp#(4), Reg#(Bit#(2))) bimodal <- replicateM(mkReg(2'b01));

    // ---- Tagged Prediction Tables (T1-T7) — one SRAM per table ----
    Vector#(NumTageTables, BpuSram64) srams <- replicateM(mkBpuSram64);

    // ---- Epoch bit for useful-bit aging ----
    Reg#(Bool) usefulEpoch <- mkReg(False);

    // ---- Latched predict context (for predictResult) ----
    Reg#(Addr)        predPc  <- mkRegU;
    Reg#(Bit#(GhrSz)) predGhr <- mkRegU;

    // ---- Update state machine registers ----
    Reg#(TageUpdState) updState <- mkReg(TageIdle);
    Reg#(Addr)         updPc    <- mkRegU;
    Reg#(Bool)         updTaken <- mkRegU;
    Reg#(Bool)         updMis   <- mkRegU;
    Reg#(Bit#(GhrSz))  updGhr   <- mkRegU;

    // ---- Helper Functions ----

    function Integer getHistoryLen(Integer tableIdx);
        return case (tableIdx)
            0: valueOf(TAGE_HL1);
            1: valueOf(TAGE_HL2);
            2: valueOf(TAGE_HL3);
            3: valueOf(TAGE_HL4);
            4: valueOf(TAGE_HL5);
            5: valueOf(TAGE_HL6);
            6: valueOf(TAGE_HL7);
            default: 0;
        endcase;
    endfunction

    function Bit#(LogTageEntries) foldHistory(Bit#(GhrSz) hist, Integer histLen);
        Bit#(LogTageEntries) result = 0;
        for (Integer i = 0; i < valueOf(GhrSz); i = i + 1) begin
            if (i < histLen) begin
                Integer outBit = i % valueOf(LogTageEntries);
                result[outBit] = result[outBit] ^ hist[i];
            end
        end
        return result;
    endfunction

    function Bit#(TageTagSz) foldHistoryTag(Bit#(GhrSz) hist, Integer histLen);
        Bit#(TageTagSz) result = 0;
        for (Integer i = 0; i < valueOf(GhrSz); i = i + 1) begin
            if (i < histLen) begin
                Integer outBit = i % valueOf(TageTagSz);
                result[outBit] = result[outBit] ^ hist[i];
            end
        end
        return result;
    endfunction

    function Bit#(4) getBimodalIndex(Addr pc);
        return truncate(pc >> 2);
    endfunction

    function Bit#(LogTageEntries) getTageIndex(Bit#(GhrSz) hist, Addr pc, Integer histLen);
        Bit#(LogTageEntries) pcIdx = truncate(pc >> 2);
        Bit#(LogTageEntries) histIdx = foldHistory(hist, histLen);
        return pcIdx ^ histIdx;
    endfunction

    function Bit#(TageTagSz) getTageTag(Bit#(GhrSz) hist, Addr pc, Integer histLen);
        Bit#(TageTagSz) pcTag = truncate(pc >> (2 + valueOf(LogTageEntries)));
        Bit#(TageTagSz) histTag = foldHistoryTag(hist, histLen);
        return pcTag ^ histTag;
    endfunction

    function Bool ctrToPrediction(Int#(TageCtrSz) ctr);
        return (ctr >= 0);
    endfunction

    function Int#(TageCtrSz) updateCtr(Int#(TageCtrSz) ctr, Bool taken);
        if (taken)
            return (ctr < 3) ? ctr + 1 : ctr;
        else
            return (ctr > -4) ? ctr - 1 : ctr;
    endfunction

    function Bit#(TageUseSz) updateUsefulness(Bit#(TageUseSz) u, Bool increment);
        if (increment)
            return (u == 3) ? 3 : u + 1;
        else
            return (u == 0) ? 0 : u - 1;
    endfunction

    function Bit#(2) updateBimodalCtr(Bit#(2) ctr, Bool taken);
        return case (ctr)
            2'b00: (taken ? 2'b01 : 2'b00);
            2'b01: (taken ? 2'b10 : 2'b00);
            2'b10: (taken ? 2'b11 : 2'b01);
            2'b11: (taken ? 2'b11 : 2'b10);
        endcase;
    endfunction

    // ---- Update state machine: cycle 1 (TageRead -> TageIdle) ----
    // Read SRAM outputs, re-derive provider/alt, compute the final provider
    // entry (new ctr + new usefulness, written once), issue any allocation /
    // usefulness-decrement writes.
    rule finishUpdate (updState == TageRead);
        Addr        pc    = updPc;
        Bool        taken = updTaken;
        Bool        mispr = updMis;
        Bit#(GhrSz) ghr   = updGhr;

        Bit#(4) bIdx = getBimodalIndex(pc);
        Integer prov = -1;
        Integer alt  = -1;
        Bit#(LogTageEntries) pIdx = 0;

        for (Integer t = valueOf(NumTageTables) - 1; t >= 0; t = t - 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(TageTagSz) tag = getTageTag(ghr, pc, hLen);
            TageEntry entry = unpackTageWord(srams[t].read);
            if (entry.tag == tag) begin
                if (prov == -1) begin
                    prov = t;
                    pIdx = getTageIndex(ghr, pc, hLen);
                end else if (alt == -1) begin
                    alt = t;
                end
            end
        end

        // ---- Provider: compute new ctr + new usefulness, write once ----
        if (prov >= 0) begin
            TageEntry provEntry = unpackTageWord(srams[prov].read);

            // Usefulness update uses the OLD counter (the prediction that was
            // actually made), compared against the alternate's prediction.
            Bool provCorrect = (ctrToPrediction(provEntry.ctr) == taken);
            Bool altPred;
            if (alt >= 0) begin
                TageEntry altEntry = unpackTageWord(srams[alt].read);
                altPred = ctrToPrediction(altEntry.ctr);
            end else begin
                altPred = (bimodal[bIdx][1] == 1'b1);
            end
            Bool altCorrect = (altPred == taken);

            Bit#(TageUseSz) newU = provEntry.u;
            if (provCorrect && !altCorrect)
                newU = updateUsefulness(provEntry.u, True);
            else if (!provCorrect && altCorrect)
                newU = updateUsefulness(provEntry.u, False);

            TageEntry newProvEntry = TageEntry{
                tag: provEntry.tag,
                ctr: updateCtr(provEntry.ctr, taken),
                u:   newU
            };
            srams[prov].put(8'hFF, padTageAddr(pIdx), packTageWord(newProvEntry));
        end else begin
            // No provider: update bimodal counter.
            bimodal[bIdx] <= updateBimodalCtr(bimodal[bIdx], taken);
        end

        // ---- On misprediction: allocate in a longer table ----
        if (mispr) begin
            Integer allocTarget = -1;
            Integer startTable = (prov >= 0) ? prov + 1 : 0;
            for (Integer t = startTable; t < valueOf(NumTageTables); t = t + 1) begin
                if (allocTarget < 0) begin
                    TageEntry e = unpackTageWord(srams[t].read);
                    if (e.u == 0)
                        allocTarget = t;
                end
            end

            if (allocTarget >= 0) begin
                Integer t = allocTarget;
                Integer hLen = getHistoryLen(t);
                Bit#(LogTageEntries) idx = getTageIndex(ghr, pc, hLen);
                Bit#(TageTagSz) tag = getTageTag(ghr, pc, hLen);
                Int#(TageCtrSz) initCtr = taken ? 1 : -1;
                srams[t].put(8'hFF, padTageAddr(idx),
                    packTageWord(TageEntry{tag: tag, ctr: initCtr, u: 1}));
            end else if (prov >= 0) begin
                // No free slot: decrement usefulness in longer tables.
                for (Integer t = prov + 1; t < valueOf(NumTageTables); t = t + 1) begin
                    TageEntry e = unpackTageWord(srams[t].read);
                    e.u = updateUsefulness(e.u, False);
                    Integer hLen = getHistoryLen(t);
                    Bit#(LogTageEntries) idx = getTageIndex(ghr, pc, hLen);
                    srams[t].put(8'hFF, padTageAddr(idx), packTageWord(e));
                end
            end
        end

        updState <= TageIdle;
    endrule

    // ---- startPredict: issue 7 SRAM reads, latch pc+ghr ----
    method Action startPredict(Addr pc, Bit#(GhrSz) ghr) if (updState == TageIdle);
        predPc  <= pc;
        predGhr <= ghr;
        for (Integer t = 0; t < valueOf(NumTageTables); t = t + 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(LogTageEntries) idx = getTageIndex(ghr, pc, hLen);
            srams[t].put(8'h00, padTageAddr(idx), 0);   // wea=0: read
        end
    endmethod

    // ---- predictResult: read SRAM outputs, pick provider/alt ----
    method TagePredInfo predictResult();
        Addr        pc  = predPc;
        Bit#(GhrSz) ghr = predGhr;

        Bit#(4) bIdx = getBimodalIndex(pc);
        Bit#(2) bctr = bimodal[bIdx];
        Bool bimodalPred = (bctr[1] == 1'b1);

        Bool prediction = bimodalPred;
        Integer prov = -1;       // -1 = bimodal, 0-6 = T1-T7
        Integer alt  = -1;
        Bit#(LogTageEntries) pIdx = 0;

        for (Integer t = valueOf(NumTageTables) - 1; t >= 0; t = t - 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(TageTagSz) tag = getTageTag(ghr, pc, hLen);
            TageEntry entry = unpackTageWord(srams[t].read);

            if (entry.tag == tag) begin
                if (prov == -1) begin
                    prediction = ctrToPrediction(entry.ctr);
                    prov = t;
                    pIdx = getTageIndex(ghr, pc, hLen);
                end else if (alt == -1) begin
                    alt = t;
                end
            end
        end

        Bit#(3) prov_bits = (prov >= 0) ? fromInteger(prov + 1) : 0;
        Bit#(3) alt_bits  = (alt >= 0)  ? fromInteger(alt + 1)  : 0;
        TageMeta meta = packTageMeta(prov_bits, alt_bits, pIdx, bIdx);

        return TagePredInfo{
            valid: (prov >= 0),
            taken: prediction,
            meta:  meta
        };
    endmethod

    // ---- update: 2-cycle state machine ----
    // Cycle 0: latch inputs, issue 7 reads.
    method Action update(Addr pc, Bool taken, Bool mispredict, Bit#(GhrSz) ghr)
            if (updState == TageIdle);
        updPc    <= pc;
        updTaken <= taken;
        updMis   <= mispredict;
        updGhr   <= ghr;
        for (Integer t = 0; t < valueOf(NumTageTables); t = t + 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(LogTageEntries) idx = getTageIndex(ghr, pc, hLen);
            srams[t].put(8'h00, padTageAddr(idx), 0);
        end
        updState <= TageRead;
    endmethod

    // ---- Restore (write) ----
    method Action restoreEntry(
        Bit#(3) table_id,
        Bit#(LogTageEntries) index,
        TageEntry oldEntry
    ) if (updState == TageIdle);
        // table_id is 0-6 for T1-T7
        srams[table_id].put(8'hFF, padTageAddr(index), packTageWord(oldEntry));
    endmethod

    method Action restoreBimodal(Bit#(4) index, Bit#(2) oldCtr);
        bimodal[index] <= oldCtr;
    endmethod

    // ---- Epoch-based useful-bit aging (toggle only, no table scan) ----
    method Action usefulBitAging();
        usefulEpoch <= !usefulEpoch;
    endmethod

endmodule
