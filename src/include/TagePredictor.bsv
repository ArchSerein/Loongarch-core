import Types::*;
import ProcTypes::*;
import BranchPredTypes::*;
import Vector::*;

// ============================================================================
// TAGE (TAgged GEometric) Direction Predictor
// ============================================================================
// Refactored from tmp/TAGE.bsv.
// Key changes from demo:
//   - GHR is an external input (managed by GlobalHistory module)
//   - predict() returns TagePredInfo with provider/alternate metadata
//   - restoreEntry() supports undo log recovery
//   - usefulBitReset() for periodic aging (via epoch bit)
//
// Architecture:
//   Base bimodal table (T0): 16 entries, 2-bit counter
//   Tagged tables (T1-T7): 32 entries each, {tag, signed-ctr, usefulness}
//   History lengths: 4, 8, 16, 32, 64, 128, 256 (geometric progression)
// ============================================================================

// ---- TageMeta Packing Helpers ----
// Pack provider/alternate table IDs and indices into a single bit-vector.
// Encoding:
//   [15:13] provider_table  (0=bimodal, 1-7=T1-T7)
//   [12:10] alternate_table (0=none/bimodal)
//   [9:5]   provider_index  (5 bits for 32-entry tables)
//   [4:0]   bimodal_index   (5 bits, only 4 LSBs used for 16-entry table)

function TageMeta packTageMeta(
    Bit#(3) prov_table,
    Bit#(3) alt_table,
    Bit#(LogTageEntries) prov_idx,
    Bit#(5) bimodal_idx
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
    return meta[9:5];
endfunction

function Bit#(5) unpackBimodalIndex(TageMeta meta);
    return meta[4:0];
endfunction

// ---- Module Interface ----

interface TagePredictor;
    // Predict branch direction for a given PC and global history
    method TagePredInfo predict(Addr pc, Bit#(GhrSz) ghr);

    // Update predictor state with actual branch outcome
    // - pc: branch instruction address
    // - taken: actual branch outcome
    // - mispredict: whether prediction was wrong
    // - ghr: global history at prediction time (used for index calculation)
    method Action update(Addr pc, Bool taken, Bool mispredict, Bit#(GhrSz) ghr);

    // Restore a specific TAGE table entry (undo log recovery)
    method Action restoreEntry(
        Bit#(3) table_id,         // 0-6 for T1-T7
        Bit#(LogTageEntries) index,
        TageEntry oldEntry
    );

    // Restore bimodal table entry (undo log recovery)
    method Action restoreBimodal(Bit#(4) index, Bit#(2) oldCtr);

    // Periodic useful-bit aging (epoch-based, called at commit)
    method Action usefulBitAging();

    // Read raw entry for undo log capture
    method TageEntry getEntry(Bit#(3) table_id, Bit#(LogTageEntries) index);
    method Bit#(2) getBimodalCtr(Bit#(4) index);
endinterface

// ---- Module Implementation ----

module mkTagePredictor(TagePredictor);

    // ---- Base Bimodal Predictor Table (T0) ----
    Vector#(TExp#(4), Reg#(Bit#(2))) bimodal <- replicateM(mkReg(2'b01)); // weak not-taken

    // ---- Tagged Prediction Tables (T1-T7) ----
    Vector#(NumTageTables, Vector#(TageEntries, Reg#(TageEntry))) tageTables;
    for (Integer t = 0; t < valueOf(NumTageTables); t = t + 1)
        tageTables[t] <- replicateM(mkReg(TageEntry{tag: 0, ctr: 0, u: 0}));

    // ---- Epoch bit for useful-bit aging ----
    // Toggles periodically to reset all usefulness counters without a table scan
    Reg#(Bool) usefulEpoch <- mkReg(False);

    // ---- Helper Functions ----

    function Integer getHistoryLen(Integer tableIdx);
        return case (tableIdx)
            0: valueOf(TAGE_HL1);   // T1: 4
            1: valueOf(TAGE_HL2);   // T2: 8
            2: valueOf(TAGE_HL3);   // T3: 16
            3: valueOf(TAGE_HL4);   // T4: 32
            4: valueOf(TAGE_HL5);   // T5: 64
            5: valueOf(TAGE_HL6);   // T6: 128
            6: valueOf(TAGE_HL7);   // T7: 256
            default: 0;
        endcase;
    endfunction

    // Fold GHR into LogTageEntries bits by XOR-ing chunks
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

    // Fold GHR into TageTagSz bits for tag computation
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

    // Bimodal table index
    function Bit#(4) getBimodalIndex(Addr pc);
        return truncate(pc >> 2);
    endfunction

    // TAGE table index = PC XOR folded history
    function Bit#(LogTageEntries) getTageIndex(Bit#(GhrSz) hist, Addr pc, Integer histLen);
        Bit#(LogTageEntries) pcIdx = truncate(pc >> 2);
        Bit#(LogTageEntries) histIdx = foldHistory(hist, histLen);
        return pcIdx ^ histIdx;
    endfunction

    // TAGE tag = PC upper bits XOR folded history
    function Bit#(TageTagSz) getTageTag(Bit#(GhrSz) hist, Addr pc, Integer histLen);
        Bit#(TageTagSz) pcTag = truncate(pc >> (2 + valueOf(LogTageEntries)));
        Bit#(TageTagSz) histTag = foldHistoryTag(hist, histLen);
        return pcTag ^ histTag;
    endfunction

    function Bool ctrToPrediction(Int#(TageCtrSz) ctr);
        return (ctr >= 0);
    endfunction

    function Int#(TageCtrSz) updateCtr(Int#(TageCtrSz) ctr, Bool taken);
        if (taken) begin
            return (ctr < 3) ? ctr + 1 : ctr;
        end else begin
            return (ctr > -4) ? ctr - 1 : ctr;
        end
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

    // ---- Helper: find allocation target ----
    function Integer findAllocTarget(Integer startTable, Addr apc, Bit#(GhrSz) aghr);
        Bit#(NumTageTables) candidates = 0;
        for (Integer t = startTable; t < valueOf(NumTageTables); t = t + 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(LogTageEntries) idx = getTageIndex(aghr, apc, hLen);
            TageEntry entry = tageTables[t][idx];
            if (entry.u == 0)
                candidates[t] = 1;
        end
        Integer result = -1;
        if (startTable <= 0 && candidates[0] == 1) result = 0;
        else if (startTable <= 1 && candidates[1] == 1) result = 1;
        else if (startTable <= 2 && candidates[2] == 1) result = 2;
        else if (startTable <= 3 && candidates[3] == 1) result = 3;
        else if (startTable <= 4 && candidates[4] == 1) result = 4;
        else if (startTable <= 5 && candidates[5] == 1) result = 5;
        else if (startTable <= 6 && candidates[6] == 1) result = 6;
        return result;
    endfunction

    // ---- Prediction ----
    method TagePredInfo predict(Addr pc, Bit#(GhrSz) ghr);
        Bit#(4) bIdx = getBimodalIndex(pc);
        Bit#(2) bctr = bimodal[bIdx];
        Bool bimodalPred = (bctr[1] == 1'b1);

        Bool prediction = bimodalPred;
        Integer prov = -1;       // -1 = bimodal, 0-6 = T1-T7
        Integer alt  = -1;       // -1 = none/bimodal
        Bit#(LogTageEntries) pIdx = 0;

        // Search from longest history (T7) to shortest (T1)
        for (Integer t = valueOf(NumTageTables) - 1; t >= 0; t = t - 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(LogTageEntries) idx = getTageIndex(ghr, pc, hLen);
            Bit#(TageTagSz) tag = getTageTag(ghr, pc, hLen);
            TageEntry entry = tageTables[t][idx];

            if (entry.tag == tag) begin
                if (prov == -1) begin
                    prediction = ctrToPrediction(entry.ctr);
                    prov = t;
                    pIdx = idx;
                end else if (alt == -1) begin
                    alt = t;
                end
            end
        end

        // Pack: 0 = bimodal, 1-7 = T1-T7
        Bit#(3) prov_bits = (prov >= 0) ? fromInteger(prov + 1) : 0;
        Bit#(3) alt_bits  = (alt >= 0)  ? fromInteger(alt + 1)  : 0;
        Bit#(5) bimodal_5 = zeroExtend(bIdx);

        TageMeta meta = packTageMeta(prov_bits, alt_bits, pIdx, bimodal_5);

        return TagePredInfo{
            valid: (prov >= 0),
            taken: prediction,
            meta:  meta
        };
    endmethod

    // ---- Update ----
    method Action update(Addr pc, Bool taken, Bool mispredict, Bit#(GhrSz) ghr);
        // Re-derive provider/alternate from the ghr snapshot
        Bit#(4) bIdx = getBimodalIndex(pc);
        Integer prov = -1;
        Integer alt  = -1;
        Bit#(LogTageEntries) pIdx = 0;

        for (Integer t = valueOf(NumTageTables) - 1; t >= 0; t = t - 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(LogTageEntries) idx = getTageIndex(ghr, pc, hLen);
            Bit#(TageTagSz) tag = getTageTag(ghr, pc, hLen);
            TageEntry entry = tageTables[t][idx];

            if (entry.tag == tag) begin
                if (prov == -1) begin
                    prov = t;
                    pIdx = idx;
                end else if (alt == -1) begin
                    alt = t;
                end
            end
        end

        // ---- Step 1: Update provider counter ----
        if (prov >= 0) begin
            TageEntry entry = tageTables[prov][pIdx];
            entry.ctr = updateCtr(entry.ctr, taken);
            tageTables[prov][pIdx] <= entry;
        end else begin
            Bit#(2) bctr = bimodal[bIdx];
            bimodal[bIdx] <= updateBimodalCtr(bctr, taken);
        end

        // ---- Step 2: On misprediction, allocate in longer-history table ----
        if (mispredict) begin
            Integer startTable = (prov >= 0) ? prov + 1 : 0;
            Integer allocTarget = findAllocTarget(startTable, pc, ghr);

            if (allocTarget >= 0) begin
                Integer t = allocTarget;
                Integer hLen = getHistoryLen(t);
                Bit#(LogTageEntries) idx = getTageIndex(ghr, pc, hLen);
                Bit#(TageTagSz) tag = getTageTag(ghr, pc, hLen);

                Int#(TageCtrSz) initCtr = taken ? 1 : -1;
                tageTables[t][idx] <= TageEntry{
                    tag: tag,
                    ctr: initCtr,
                    u:   1
                };
            end else if (prov >= 0) begin
                // No slot available: decrement usefulness in longer-history tables
                for (Integer t = prov + 1; t < valueOf(NumTageTables); t = t + 1) begin
                    Integer hLen = getHistoryLen(t);
                    Bit#(LogTageEntries) idx = getTageIndex(ghr, pc, hLen);
                    TageEntry entry = tageTables[t][idx];
                    entry.u = updateUsefulness(entry.u, False);
                    tageTables[t][idx] <= entry;
                end
            end
        end

        // ---- Step 3: Update usefulness of provider ----
        if (prov >= 0) begin
            TageEntry entry = tageTables[prov][pIdx];

            // Determine alternate prediction
            Bool altPred;
            if (alt >= 0) begin
                TageEntry altEntry = tageTables[alt][getTageIndex(ghr, pc, getHistoryLen(alt))];
                altPred = ctrToPrediction(altEntry.ctr);
            end else begin
                Bit#(2) bctr = bimodal[bIdx];
                altPred = (bctr[1] == 1'b1);
            end

            Bool provCorrect = (ctrToPrediction(entry.ctr) == taken);
            Bool altCorrect  = (altPred == taken);

            if (provCorrect && !altCorrect) begin
                entry.u = updateUsefulness(entry.u, True);
            end else if (!provCorrect && altCorrect) begin
                entry.u = updateUsefulness(entry.u, False);
            end
            tageTables[prov][pIdx] <= entry;
        end
    endmethod

    // ---- Undo Log Recovery ----
    method Action restoreEntry(
        Bit#(3) table_id,
        Bit#(LogTageEntries) index,
        TageEntry oldEntry
    );
        tageTables[table_id][index] <= oldEntry;
    endmethod

    method Action restoreBimodal(Bit#(4) index, Bit#(2) oldCtr);
        bimodal[index] <= oldCtr;
    endmethod

    // ---- Epoch-based useful-bit aging ----
    // Called periodically (e.g., every 256K branches) to prevent staleness.
    // Toggles epoch bit; on next allocation, entries from the old epoch
    // have their usefulness cleared.
    method Action usefulBitAging();
        // Toggle global epoch — practical effect: newly allocated entries
        // use the new epoch, and stale entries are identified by old epoch.
        usefulEpoch <= !usefulEpoch;

        // Optionally: reset all usefulness bits to 0 periodically
        // (simplified approach for first version)
        for (Integer t = 0; t < valueOf(NumTageTables); t = t + 1) begin
            for (Integer i = 0; i < valueOf(TageEntries); i = i + 1) begin
                TageEntry entry = tageTables[t][i];
                entry.u = 0;
                tageTables[t][i] <= entry;
            end
        end
    endmethod

    // ---- Raw Entry Access (for undo log capture) ----
    method TageEntry getEntry(Bit#(3) table_id, Bit#(LogTageEntries) index);
        return tageTables[table_id][index];
    endmethod

    method Bit#(2) getBimodalCtr(Bit#(4) index);
        return bimodal[index];
    endmethod

endmodule
