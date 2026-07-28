import Types::*;
import ProcTypes::*;
import BranchPredTypes::*;
import BpuSRAM::*;
import Vector::*;

// ============================================================================
// ITTAGE (Indirect TAGE) Target Predictor (SRAM-backed)
// ============================================================================
// Architecture:
//   4 tagged tables (T1-T4): 64 entries each (CONFIG_ITTAGE_ENTRIES), stored
//                            in one sram_128x64_wrap instance per table
//                            (4 total). Each entry is
//                            {tag(8), target(32), conf(2)} = 42 bits packed
//                            into the low bits of the 64-bit SRAM word.
//   History lengths: 4, 16, 64, 256 (geometric progression)
//   Index = PC XOR folded path-history
//
// SRAM 1-cycle read latency forces the predict path to be split:
//   startPredict(pc, pathHist) — cycle N:   compute 4 indices/tags, issue
//                                            4 reads, latch pc+pathHist
//   predictResult()            — cycle N+1: read 4 SRAM outputs, compare
//                                            tags, return provider result
//
// update() is a 2-cycle state machine (must read provider/alternate entries
// before writing them back):
//   Idle  — update() accepted: latch inputs, issue 4 reads, -> Read
//   Read  — SRAM outputs ready: re-derive provider, compute final entry
//           (new conf + new target on mispredict, written once), issue any
//           allocation / confidence-decrement writes, -> Idle
//
// Metadata (IttageMeta, 9 bits) — repacked for 64-entry tables:
//   [8:6] provider_table (0=none, 1-4=T1-T4)
//   [5:0] provider_index (6 bits)
// ============================================================================

// ---- IttageMeta Packing Helpers ----
function IttageMeta packIttageMeta(Bit#(3) prov_table, Bit#(IttageLogEntries) prov_idx);
    return {prov_table, prov_idx};
endfunction

function Bit#(3) unpackIttageProvTable(IttageMeta meta);
    return meta[8:6];
endfunction

function Bit#(IttageLogEntries) unpackIttageProvIndex(IttageMeta meta);
    return meta[5:0];
endfunction

// ---- Pack / unpack an ITTAGE entry into a 64-bit SRAM word ----
function Bit#(64) packIttageWord(IttageEntry e);
    return zeroExtend(pack(e));
endfunction

function IttageEntry unpackIttageWord(Bit#(64) w);
    return unpack(truncate(w));
endfunction

function Bit#(7) padIttageAddr(Bit#(IttageLogEntries) idx);
    return zeroExtend(idx);
endfunction

// ---- Update state machine ----
typedef enum { IttageIdle, IttageRead } IttageUpdState deriving (Bits, Eq);

// ---- Module Interface ----

interface IttagePredictor;
    method Action startPredict(Addr pc, Bit#(IttagePathHistSz) pathHist);
    method IttagePredInfo predictResult();

    method Action update(Addr pc, Addr actualTarget, Bool mispredict,
                         Bit#(IttagePathHistSz) pathHist);

    method Action restoreEntry(
        Bit#(2) table_id,          // 0-3 for T1-T4
        Bit#(IttageLogEntries) index,
        IttageEntry oldEntry
    );
endinterface

// ---- Module Implementation ----

module mkIttagePredictor(IttagePredictor);

    // ---- Tagged Prediction Tables (T1-T4) — one SRAM per table ----
    Vector#(IttageNumTables, BpuSram64) srams <- replicateM(mkBpuSram64);

    // ---- Latched predict context (for predictResult) ----
    Reg#(Addr)                    predPc   <- mkRegU;
    Reg#(Bit#(IttagePathHistSz))  predHist <- mkRegU;

    // ---- Update state machine registers ----
    Reg#(IttageUpdState)        updState <- mkReg(IttageIdle);
    Reg#(Addr)                  updPc    <- mkRegU;
    Reg#(Addr)                  updTgt   <- mkRegU;
    Reg#(Bool)                  updMis   <- mkRegU;
    Reg#(Bit#(IttagePathHistSz)) updHist <- mkRegU;

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

    function Bit#(IttageLogEntries) getIttageIndex(Bit#(IttagePathHistSz) hist, Addr pc, Integer histLen);
        Bit#(IttageLogEntries) pcIdx = truncate(pc >> 2);
        Bit#(IttageLogEntries) histIdx = foldPathHistory(hist, histLen);
        return pcIdx ^ histIdx;
    endfunction

    function Bit#(IttageTagSz) getIttageTag(Bit#(IttagePathHistSz) hist, Addr pc, Integer histLen);
        Bit#(IttageTagSz) pcTag = truncate(pc >> (2 + valueOf(IttageLogEntries)));
        Bit#(IttageTagSz) histTag = foldPathHistoryTag(hist, histLen);
        return pcTag ^ histTag;
    endfunction

    function Bit#(IttageConfSz) updateConf(Bit#(IttageConfSz) conf, Bool increment);
        if (increment)
            return (conf == 3) ? 3 : conf + 1;
        else
            return (conf == 0) ? 0 : conf - 1;
    endfunction

    // ---- Update state machine: cycle 1 (IttageRead -> IttageIdle) ----
    // Read SRAM outputs, re-derive provider, compute the final provider entry
    // (new conf + new target on mispredict, written once), issue any
    // allocation / confidence-decrement writes.
rule finishUpdate_Correct (updState == IttageRead && !updMis);
    Addr                   pc   = updPc;
    Bit#(IttagePathHistSz) hist = updHist;

    Integer prov = -1;
    Bit#(IttageLogEntries) pIdx = 0;

    // 1. 寻找 Provider
    for (Integer t = valueOf(IttageNumTables) - 1; t >= 0; t = t - 1) begin
        Integer hLen = getHistoryLen(t);
        Bit#(IttageTagSz) tag = getIttageTag(hist, pc, hLen);
        IttageEntry entry = unpackIttageWord(srams[t].read);
        if (entry.tag == tag) begin
            if (prov == -1) begin
                prov = t;
                pIdx = getIttageIndex(hist, pc, hLen);
            end
        end
    end

    // 2. 更新 Provider: 仅增加置信度，目标地址不变
    if (prov >= 0) begin
        IttageEntry provEntry = unpackIttageWord(srams[prov].read);
        Bit#(IttageConfSz) newConf = updateConf(provEntry.conf, True); // True for correct
        IttageEntry newProvEntry = IttageEntry{
            tag:    provEntry.tag,
            target: provEntry.target, // Keep original target
            conf:   newConf
        };
        srams[prov].put(8'hFF, padIttageAddr(pIdx), packIttageWord(newProvEntry));
    end

    updState <= IttageIdle;
endrule

	rule finishUpdate_Mispredict (updState == IttageRead && updMis);
	    Addr                   pc   = updPc;
	    Addr                   tgt  = updTgt;
	    Bit#(IttagePathHistSz) hist = updHist;
	
	    Integer prov = -1;
	    Bit#(IttageLogEntries) pIdx = 0;
	
	    // 1. 寻找 Provider
	    for (Integer t = valueOf(IttageNumTables) - 1; t >= 0; t = t - 1) begin
	        Integer hLen = getHistoryLen(t);
	        Bit#(IttageTagSz) tag = getIttageTag(hist, pc, hLen);
	        IttageEntry entry = unpackIttageWord(srams[t].read);
	        if (entry.tag == tag) begin
	            if (prov == -1) begin
	                prov = t;
	                pIdx = getIttageIndex(hist, pc, hLen);
	            end
	        end
	    end
	
	    // 2. 更新 Provider: 降低置信度，更新目标地址
	    if (prov >= 0) begin
	        IttageEntry provEntry = unpackIttageWord(srams[prov].read);
	        Bit#(IttageConfSz) newConf = updateConf(provEntry.conf, False); // False for mispredict
	        IttageEntry newProvEntry = IttageEntry{
	            tag:    provEntry.tag,
	            target: tgt, // Update to the correct target
	            conf:   newConf
	        };
	        srams[prov].put(8'hFF, padIttageAddr(pIdx), packIttageWord(newProvEntry));
	    end
	
	    // 3. 分配或降级 (Allocation / Penalty)
	    Integer allocTarget = -1;
	    Integer startTable = (prov >= 0) ? prov + 1 : 0;
	    
	    // 3.1 寻找 conf 为 0 的表
	    for (Integer t = startTable; t < valueOf(IttageNumTables); t = t + 1) begin
	        if (allocTarget < 0) begin
	            IttageEntry e = unpackIttageWord(srams[t].read);
	            if (e.conf == 0)
	                allocTarget = t;
	        end
	    end
	
	    // 3.2 执行分配或降级置信度
	    if (allocTarget >= 0) begin
	        Integer t = allocTarget;
	        Integer hLen = getHistoryLen(t);
	        Bit#(IttageLogEntries) idx = getIttageIndex(hist, pc, hLen);
	        Bit#(IttageTagSz) tag = getIttageTag(hist, pc, hLen);
	        srams[t].put(8'hFF, padIttageAddr(idx),
	            packIttageWord(IttageEntry{tag: tag, target: tgt, conf: 1}));
	    end else if (prov >= 0) begin
	        // 没找到空位，降低长历史表的置信度以供后续驱逐
	        for (Integer t = prov + 1; t < valueOf(IttageNumTables); t = t + 1) begin
	            IttageEntry e = unpackIttageWord(srams[t].read);
	            e.conf = updateConf(e.conf, False);
	            Integer hLen = getHistoryLen(t);
	            Bit#(IttageLogEntries) idx = getIttageIndex(hist, pc, hLen);
	            srams[t].put(8'hFF, padIttageAddr(idx), packIttageWord(e));
	        end
	    end
	
	    updState <= IttageIdle;
	endrule

    // ---- startPredict: issue 4 SRAM reads, latch pc+pathHist ----
    method Action startPredict(Addr pc, Bit#(IttagePathHistSz) pathHist) if (updState == IttageIdle);
        predPc   <= pc;
        predHist <= pathHist;
        for (Integer t = 0; t < valueOf(IttageNumTables); t = t + 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(IttageLogEntries) idx = getIttageIndex(pathHist, pc, hLen);
            srams[t].put(8'h00, padIttageAddr(idx), 0);   // wea=0: read
        end
    endmethod

    // ---- predictResult: read SRAM outputs, pick provider ----
    method IttagePredInfo predictResult();
        Addr                   pc   = predPc;
        Bit#(IttagePathHistSz) hist = predHist;

        Addr predictedTarget = pc + 4;
        Bool confident = False;
        Integer prov = -1;      // -1 = no provider, 0-3 = T1-T4
        Bit#(IttageLogEntries) pIdx = 0;

        for (Integer t = valueOf(IttageNumTables) - 1; t >= 0; t = t - 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(IttageTagSz) tag = getIttageTag(hist, pc, hLen);
            IttageEntry entry = unpackIttageWord(srams[t].read);

            if (entry.tag == tag) begin
                if (prov == -1) begin
                    predictedTarget = entry.target;
                    confident = (entry.conf >= 2);
                    prov = t;
                    pIdx = getIttageIndex(hist, pc, hLen);
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

    // ---- update: 2-cycle state machine ----
    // Cycle 0: latch inputs, issue 4 reads.
    method Action update(Addr pc, Addr actualTarget, Bool mispredict,
                         Bit#(IttagePathHistSz) pathHist) if (updState == IttageIdle);
        updPc  <= pc;
        updTgt <= actualTarget;
        updMis <= mispredict;
        updHist <= pathHist;
        for (Integer t = 0; t < valueOf(IttageNumTables); t = t + 1) begin
            Integer hLen = getHistoryLen(t);
            Bit#(IttageLogEntries) idx = getIttageIndex(pathHist, pc, hLen);
            srams[t].put(8'h00, padIttageAddr(idx), 0);
        end
        updState <= IttageRead;
    endmethod

    // ---- Restore (write) ----
    method Action restoreEntry(
        Bit#(2) table_id,
        Bit#(IttageLogEntries) index,
        IttageEntry oldEntry
    ) if (updState == IttageIdle);
        srams[table_id].put(8'hFF, padIttageAddr(index), packIttageWord(oldEntry));
    endmethod

endmodule
