import Types::*;
import ProcTypes::*;
import BranchPredTypes::*;
import Vector::*;

// ============================================================================
// ITTAGE (Indirect TAGE) Target Predictor
// ============================================================================
// Refactored from tmp/ITTAGE.bsv.
// Key changes from demo:
//   - Path history is an external input (managed by GlobalHistory module)
//   - predict() returns IttagePredInfo with provider metadata
//   - restoreEntry() supports undo log recovery
//
// Architecture:
//   4 tagged tables (T1-T4): 32 entries each, {partial-tag, target, confidence}
//   History lengths: 4, 16, 64, 256 (geometric progression)
//   Index = PC XOR folded path-history
// ============================================================================

// ---- IttageMeta Packing Helpers ----
// Encoding:
//   [7:5] provider_table (0=none, 1-4=T1-T4)
//   [4:0] provider_index (5 bits for 32-entry tables)

function IttageMeta packIttageMeta(Bit#(3) prov_table, Bit#(5) prov_idx);
    return {prov_table, prov_idx};
endfunction

function Bit#(3) unpackIttageProvTable(IttageMeta meta);
    return meta[7:5];
endfunction

function Bit#(5) unpackIttageProvIndex(IttageMeta meta);
    return meta[4:0];
endfunction

// ---- Module Interface ----

interface IttagePredictor;
    // Predict the target address of an indirect branch
    method IttagePredInfo predict(Addr pc, Bit#(IttagePathHistSz) pathHist);

    // Update predictor state with actual resolved target
    method Action update(Addr pc, Addr actualTarget, Bool mispredict,
                         Bit#(IttagePathHistSz) pathHist);

    // Restore a specific ITTAGE table entry (undo log recovery)
    method Action restoreEntry(
        Bit#(2) table_id,          // 0-3 for T1-T4
        Bit#(IttageLogEntries) index,
        IttageEntry oldEntry
    );

    // Read raw entry for undo log capture
    method IttageEntry getEntry(Bit#(2) table_id, Bit#(IttageLogEntries) index);
endinterface

// ---- Module Implementation ----

module mkIttagePredictor(IttagePredictor);

    // ---- Tagged Prediction Tables (T1-T4) ----
    Vector#(IttageNumTables, Vector#(IttageEntries, Reg#(IttageEntry))) ittageTables;
    for (Integer t = 0; t < valueOf(IttageNumTables); t = t + 1)
        ittageTables[t] <- replicateM(mkReg(IttageEntry{tag: 0, target: 0, conf: 0}));

    // ---- Helper Functions ----

    function Integer getHistoryLen(Integer tableIdx);
        return case (tableIdx)
            0: valueOf(IT_HL1);   // 4
            1: valueOf(IT_HL2);   // 16
            2: valueOf(IT_HL3);   // 64
            3: valueOf(IT_HL4);   // 256
            default: 0;
        endcase;
    endfunction

    // Fold path history into index bits
    function Bit#(IttageLogEntries) foldPathHistory(Bit#(IttagePathHistSz) hist, Integer histLen);
        Bit#(IttageLogEntries) result = 0;
        for (Integer i = 0; i < valueOf(IttagePathHistSz); i = i + 1) begin
            if (i < histLen) begin
                Integer outBit = i % valueOf(IttageLogEntries);
                result[outBit] = result[outBit] ^ hist[i];
            end
        end
        return result;
    endfunction

    // Fold path history into tag bits
    function Bit#(IttageTagSz) foldPathHistoryTag(Bit#(IttagePathHistSz) hist, Integer histLen);
        Bit#(IttageTagSz) result = 0;
        for (Integer i = 0; i < valueOf(IttagePathHistSz); i = i + 1) begin
            if (i < histLen) begin
                Integer outBit = i % valueOf(IttageTagSz);
                result[outBit] = result[outBit] ^ hist[i];
            end
        end
        return result;
    endfunction

    // ITTAGE table index = PC XOR folded path history
    function Bit#(IttageLogEntries) getIttageIndex(Bit#(IttagePathHistSz) hist, Addr pc, Integer histLen);
        Bit#(IttageLogEntries) pcIdx = truncate(pc >> 2);
        Bit#(IttageLogEntries) histIdx = foldPathHistory(hist, histLen);
        return pcIdx ^ histIdx;
    endfunction

    // ITTAGE tag = PC upper bits XOR folded path history
    function Bit#(IttageTagSz) getIttageTag(Bit#(IttagePathHistSz) hist, Addr pc, Integer histLen);
        Bit#(IttageTagSz) pcTag = truncate(pc >> (2 + valueOf(IttageLogEntries)));
        Bit#(IttageTagSz) histTag = foldPathHistoryTag(hist, histLen);
        return pcTag ^ histTag;
    endfunction

    // Confidence counter update
    function Bit#(IttageConfSz) updateConf(Bit#(IttageConfSz) conf, Bool increment);
        if (increment)
            return (conf == 3) ? 3 : conf + 1;
        else
            return (conf == 0) ? 0 : conf - 1;
    endfunction

    // ---- Helper: find allocation target ----
    function Integer findIttageAllocTarget(Integer startTable, Addr apc, Bit#(IttagePathHistSz) aphist);
        Bit#(IttageNumTables) candidates = 0;
        for (Integer t = startTable; t < valueOf(IttageNumTables); t = t + 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(IttageLogEntries) idx = getIttageIndex(aphist, apc, hLen);
            IttageEntry entry = ittageTables[t][idx];
            if (entry.conf == 0)
                candidates[t] = 1;
        end
        Integer result = -1;
        if (startTable <= 0 && candidates[0] == 1) result = 0;
        else if (startTable <= 1 && candidates[1] == 1) result = 1;
        else if (startTable <= 2 && candidates[2] == 1) result = 2;
        else if (startTable <= 3 && candidates[3] == 1) result = 3;
        return result;
    endfunction

    // ---- Prediction ----
    method IttagePredInfo predict(Addr pc, Bit#(IttagePathHistSz) pathHist);
        Addr predictedTarget = pc + 4;
        Bool confident = False;
        Integer prov = -1;      // -1 = no provider, 0-3 = T1-T4
        Bit#(5) pIdx = 0;

        // Search from longest history to shortest
        for (Integer t = valueOf(IttageNumTables) - 1; t >= 0; t = t - 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(IttageLogEntries) idx = getIttageIndex(pathHist, pc, hLen);
            Bit#(IttageTagSz) tag = getIttageTag(pathHist, pc, hLen);
            IttageEntry entry = ittageTables[t][idx];

            if (entry.tag == tag) begin
                if (prov == -1) begin
                    predictedTarget = entry.target;
                    confident = (entry.conf >= 2);
                    prov = t;
                    pIdx = idx;
                end
            end
        end

        Bit#(3) prov_bits = (prov >= 0) ? fromInteger(prov + 1) : 0;
        IttageMeta meta = packIttageMeta(prov_bits, pIdx);

        return IttagePredInfo{
            valid:     (prov >= 0),
            target:    predictedTarget,
            confident: confident,
            meta:      meta
        };
    endmethod

    // ---- Update ----
    method Action update(Addr pc, Addr actualTarget, Bool mispredict,
                         Bit#(IttagePathHistSz) pathHist);
        // Re-derive provider from the pathHist snapshot
        Integer prov = -1;
        Bit#(5) pIdx = 0;

        for (Integer t = valueOf(IttageNumTables) - 1; t >= 0; t = t - 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(IttageLogEntries) idx = getIttageIndex(pathHist, pc, hLen);
            Bit#(IttageTagSz) tag = getIttageTag(pathHist, pc, hLen);
            IttageEntry entry = ittageTables[t][idx];

            if (entry.tag == tag) begin
                if (prov == -1) begin
                    prov = t;
                    pIdx = idx;
                end
            end
        end

        // ---- Step 1: Update provider entry's confidence and target ----
        if (prov >= 0) begin
            IttageEntry entry = ittageTables[prov][pIdx];

            if (mispredict) begin
                entry.conf = updateConf(entry.conf, False);
            end else begin
                entry.conf = updateConf(entry.conf, True);
            end
            ittageTables[prov][pIdx] <= entry;
        end

        // ---- Step 2: On misprediction, allocate in longer-history table ----
        if (mispredict) begin
            Integer startTable = (prov >= 0) ? prov + 1 : 0;
            Integer allocTarget = findIttageAllocTarget(startTable, pc, pathHist);

            if (allocTarget >= 0) begin
                Integer t = allocTarget;
                Integer hLen = getHistoryLen(t);
                Bit#(IttageLogEntries) idx = getIttageIndex(pathHist, pc, hLen);
                Bit#(IttageTagSz) tag = getIttageTag(pathHist, pc, hLen);

                ittageTables[t][idx] <= IttageEntry{
                    tag:    tag,
                    target: actualTarget,
                    conf:   1
                };
            end else if (prov >= 0) begin
                // No zero-confidence slot: decrement all confidence in longer tables
                for (Integer t = prov + 1; t < valueOf(IttageNumTables); t = t + 1) begin
                    Integer hLen = getHistoryLen(t);
                    Bit#(IttageLogEntries) idx = getIttageIndex(pathHist, pc, hLen);
                    IttageEntry entry = ittageTables[t][idx];
                    entry.conf = updateConf(entry.conf, False);
                    ittageTables[t][idx] <= entry;
                end
            end

            // Update provider entry's target if allocation succeeded or failed
            if (prov >= 0) begin
                IttageEntry entry = ittageTables[prov][pIdx];
                entry.target = actualTarget;
                ittageTables[prov][pIdx] <= entry;
            end
        end
    endmethod

    // ---- Undo Log Recovery ----
    method Action restoreEntry(
        Bit#(2) table_id,
        Bit#(IttageLogEntries) index,
        IttageEntry oldEntry
    );
        ittageTables[table_id][index] <= oldEntry;
    endmethod

    // ---- Raw Entry Access ----
    method IttageEntry getEntry(Bit#(2) table_id, Bit#(IttageLogEntries) index);
        return ittageTables[table_id][index];
    endmethod

endmodule
