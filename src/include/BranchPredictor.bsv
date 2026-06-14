import Types::*;
import ProcTypes::*;
import BranchPredTypes::*;
import SmallBtb::*;
import Mbtb::*;
import TagePredictor::*;
import IttagePredictor::*;
import GlobalHistory::*;
import PredMeta::*;
import Vector::*;

// ============================================================================
// Branch Prediction Unit — Top-Level Integration
// ============================================================================
// Integrates all sub-predictors into a two-layer branch prediction system:
//
//   Layer 1 (Fast Path, P0):  SmallBtb + 2-bit counter -> next PC every cycle
//   Layer 2 (Accurate Path):  mBTB + TAGE + ITTAGE -> late override
//
// Prediction Pipeline (design doc §6):
//   P0:  predict()        -> fast_next_pc
//   P1:  startAccurate()  -> mBTB + TAGE/ITTAGE indexing
//   P2:  getAccurateResult() -> TAGE + mBTB results available
//   P3:  getAccurateResult() -> ITTAGE results available
//
// Training (design doc §9):
//   Execute stage: speculative update with undo log
//   Commit stage:  confirm or roll back
// ============================================================================

function Addr refinedNextPc(BPUResult res, Addr pc);
    Addr result = pc + 4;

    if (res.mbtb_hit) begin
        case (res.mbtb_cfi)
            CFI_COND: begin
                if (res.tage.valid)
                    result = res.tage.taken ? res.mbtb_target : (pc + 4);
                else
                    result = res.fast.taken ? res.fast.target : (pc + 4);
            end
            CFI_JAL, CFI_CALL:
                result = res.mbtb_target;
            CFI_JALR, CFI_ICALL, CFI_RET: begin
                if (res.ittage.valid && res.ittage.confident)
                    result = res.ittage.target;
                else
                    result = res.mbtb_target;
            end
        endcase
    end

    return result;
endfunction

interface BranchPredictor;
    method Addr predict(Addr pc);
    method FastPredInfo getFastInfo(Addr pc);
    method Action startAccurate(Addr pc);
    method ActionValue#(BPUResult) getAccurateResult();
    method Addr getRefinedPc(Addr pc);
    method Bool needsOverride(Addr pc);

    method Action executeUpdate(
        Addr pc, Addr actualTarget, Bool actualTaken, CfiType cfiType
    );

    method Action commit(Addr pc);
    method ActionValue#(Maybe#(PredictorUndoEntry)) rollbackStep();
    method Bool needRollback(Addr pc);
    method UndoLogPtr getRollbackTarget(Addr pc);

    method Bit#(GhrSz) getGhr();
    method Bit#(IttagePathHistSz) getPathHist();

    method Action reset();
    method Action usefulBitAging();
endinterface

(* synthesize *)
module mkBranchPredictor(BranchPredictor);

    SmallBtb        smallBtb  <- mkSmallBtb;
    MBtb            mbtb      <- mkMBtb;
    TagePredictor   tage      <- mkTagePredictor;
    IttagePredictor ittage    <- mkIttagePredictor;
    GlobalHistory   hist      <- mkGlobalHistory;
    PredictionQueue predQueue <- mkPredictionQueue;
    UndoLog         undoLog   <- mkUndoLog;

    Reg#(Addr)          accPc       <- mkRegU;
    Reg#(HistSnapshot)  accHist     <- mkRegU;
    Reg#(Bool)          accValid    <- mkReg(False);
    Reg#(Addr)          lastRefinedPc <- mkRegU;

    Reg#(UndoLogPtr) rollbackTarget <- mkReg(0);
    Reg#(UndoLogPtr) rollbackPos    <- mkReg(0);
    Reg#(Bool)       rollbackActive <- mkReg(False);

    function Bit#(UndoOldValueSz) packSmallBtb(SmallBtbEntry e);
        return zeroExtend(pack(e));
    endfunction
    function SmallBtbEntry unpackSmallBtb(Bit#(UndoOldValueSz) v);
        return unpack(truncate(v));
    endfunction

    function Bit#(UndoOldValueSz) packMbtb(MBtbEntry e);
        return zeroExtend(pack(e));
    endfunction
    function MBtbEntry unpackMbtb(Bit#(UndoOldValueSz) v);
        return unpack(truncate(v));
    endfunction

    function Bit#(UndoOldValueSz) packTage(TageEntry e);
        return zeroExtend(pack(e));
    endfunction
    function TageEntry unpackTage(Bit#(UndoOldValueSz) v);
        return unpack(truncate(v));
    endfunction

    function Bit#(UndoOldValueSz) packIttage(IttageEntry e);
        return zeroExtend(pack(e));
    endfunction
    function IttageEntry unpackIttage(Bit#(UndoOldValueSz) v);
        return unpack(truncate(v));
    endfunction

    method Addr predict(Addr pc);
        return smallBtb.nextPc(pc);
    endmethod

    method FastPredInfo getFastInfo(Addr pc);
        return smallBtb.predict(pc);
    endmethod

    method Action startAccurate(Addr pc);
        accHist  <= hist.snapshot();
        accPc    <= pc;
        accValid <= True;
    endmethod

    method ActionValue#(BPUResult) getAccurateResult() if (accValid);
        Maybe#(MBtbEntry) mbtbRes = mbtb.lookup(accPc);
        TagePredInfo     tageRes  = tage.predict(accPc, accHist.ghist_snapshot);
        IttagePredInfo   ittagRes = ittage.predict(accPc, accHist.phist_snapshot);
        FastPredInfo     fastInfo = smallBtb.predict(accPc);

        Bool    hit = isValid(mbtbRes);
        CfiType cfi = hit ? fromMaybe(?, mbtbRes).cfi_type : CFI_NONE;
        Addr    tgt = hit ? fromMaybe(?, mbtbRes).target : (accPc + 4);

        BPUResult result = BPUResult{
            fast:        fastInfo,
            mbtb_hit:    hit,
            mbtb_cfi:    cfi,
            mbtb_target: tgt,
            tage:        tageRes,
            ittage:      ittagRes
        };

        lastRefinedPc <= refinedNextPc(result, accPc);

        if (cfi != CFI_NONE && predQueue.notFull()) begin
            PredMeta meta;
            meta.pc           = accPc;
            meta.fast_valid   = fastInfo.valid;
            meta.fast_taken   = fastInfo.taken;
            meta.fast_target  = fastInfo.target;
            meta.cfi_type     = cfi;
            if (hit) begin
                MBtbEntry me = fromMaybe(?, mbtbRes);
                meta.mbtb_hit = True;
                meta.mbtb_idx = mbtb.getIndex(accPc);
                meta.mbtb_tag = me.tag;
            end else begin
                meta.mbtb_hit = False;
                meta.mbtb_idx = 0;
                meta.mbtb_tag = 0;
            end
            meta.tage_valid    = tageRes.valid;
            meta.tage_taken    = tageRes.taken;
            meta.tage_meta     = tageRes.meta;
            meta.ittage_valid  = ittagRes.valid;
            meta.ittage_target = ittagRes.target;
            meta.ittage_meta   = ittagRes.meta;
            meta.hist_snapshot = accHist;
            predQueue.enq(meta);
        end

        accValid <= False;
        return result;
    endmethod

    method Addr getRefinedPc(Addr pc);
        return lastRefinedPc;
    endmethod

    method Bool needsOverride(Addr pc);
        return lastRefinedPc != smallBtb.nextPc(pc);
    endmethod

    method Action executeUpdate(
        Addr pc, Addr actualTarget, Bool actualTaken, CfiType cfiType
    );
        smallBtb.update(pc, cfiType, actualTarget, actualTaken);
        mbtb.update(pc, cfiType, actualTarget);

        if (cfiType == CFI_COND) begin
            hist.updateGhr(actualTaken);
        end else if (cfiType == CFI_JAL || cfiType == CFI_CALL) begin
            hist.updateGhr(True);
        end else if (cfiType == CFI_JALR || cfiType == CFI_ICALL || cfiType == CFI_RET) begin
            hist.updatePathHist(actualTarget);
        end
    endmethod

    method Action commit(Addr pc);
        predQueue.deq(pc);
    endmethod

    method ActionValue#(Maybe#(PredictorUndoEntry)) rollbackStep();
        Maybe#(PredictorUndoEntry) result = tagged Invalid;

        if (rollbackActive && rollbackPos != rollbackTarget) begin
            undoLog.pop();
            UndoLogPtr idx = undoLog.getTail();
            PredictorUndoEntry e = undoLog.read(idx);

            case (e.upd_type)
                UPD_SMALL_BTB: begin
                    SmallBtbEntry oldEntry = unpackSmallBtb(e.old_value);
                    smallBtb.restore(truncate(e.index), oldEntry);
                end
                UPD_MBTB: begin
                    MBtbEntry oldEntry = unpackMbtb(e.old_value);
                    mbtb.restore(truncate(e.index), oldEntry);
                end
                UPD_TAGE_TAGGED: begin
                    TageEntry oldEntry = unpackTage(e.old_value);
                    tage.restoreEntry(e.table_id, truncate(e.index), oldEntry);
                end
                UPD_ITTAGE_TAGGED: begin
                    IttageEntry oldEntry = unpackIttage(e.old_value);
                    ittage.restoreEntry(truncate(e.table_id), truncate(e.index), oldEntry);
                end
                UPD_GHIST, UPD_PHIST: begin
                end
            endcase

            rollbackPos <= rollbackPos + 1;
            result = tagged Valid e;
        end

        return result;
    endmethod

    method Bool needRollback(Addr pc);
        return isValid(predQueue.lookup(pc));
    endmethod

    method UndoLogPtr getRollbackTarget(Addr pc);
        return 0;
    endmethod

    method Bit#(GhrSz) getGhr();
        return hist.ghr();
    endmethod

    method Bit#(IttagePathHistSz) getPathHist();
        return hist.pathHist();
    endmethod

    method Action reset();
        hist.reset();
        predQueue.clear();
        undoLog.reset();
        accValid <= False;
        rollbackActive <= False;
    endmethod

    method Action usefulBitAging();
        tage.usefulBitAging();
    endmethod

endmodule
