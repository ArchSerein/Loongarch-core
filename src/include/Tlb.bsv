import Types::*;
import ProcTypes::*;
import Vector::*;
import ConfigReg::*;
`include "CsrAddr.bsv"
`include "Autoconf.bsv"

// ============================================================
// Configurable parameters
// ============================================================
typedef `CONFIG_TLB_ENTRIES TlbNumEntries;
typedef TLog#(TlbNumEntries) TlbIndexSz;
typedef Bit#(TlbIndexSz)     TlbIndex;

// Number of pipeline stages for search = log2(TLB_ENTRIES)
typedef TLog#(TlbNumEntries) TlbSearchStages;

// ============================================================
// TLB entry stored internally (odd/even page pair)
// ============================================================
typedef struct {
    Bool     e;       // Exist bit
    Bit#(10) asid;    // Address Space Identifier
    Bool     g;       // Global bit
    Bit#(6)  ps;      // Page Size exponent
    Bit#(19) vppn;    // Virtual double page number [31:13]
    // Even page (page0)
    Bool     v0;
    Bool     d0;
    Bit#(2)  mat0;
    Bit#(2)  plv0;
    Bit#(20) ppn0;    // Physical page number [31:12]
    // Odd page (page1)
    Bool     v1;
    Bool     d1;
    Bit#(2)  mat1;
    Bit#(2)  plv1;
    Bit#(20) ppn1;
} TlbEntry deriving(Bits, Eq);

// ============================================================
// Read result returned to CsrFile
// ============================================================
typedef struct {
    Bool    ne;      // Not-exist (inverse of E)
    Bit#(6) ps;
    Data    ehi;     // TLBEHI value
    Data    elo0;    // TLBELO0 value
    Data    elo1;    // TLBELO1 value
    Data    asid;
} TlbReadResult deriving(Bits, Eq);

// ============================================================
// Intermediate search result per entry
// ============================================================
typedef struct {
    Bool     hit;
    TlbIndex idx;
    Bit#(6)  ps;
} TlbSearchEntry deriving(Bits, Eq);

function TlbSearchEntry noSearchHit;
    return TlbSearchEntry { hit: False, idx: 0, ps: 0 };
endfunction

// Pick the winner between two search results (first hit wins)
function TlbSearchEntry pickSearchWinner(TlbSearchEntry a, TlbSearchEntry b);
    if (a.hit) return a;
    else       return b;
endfunction

// ============================================================
// Interface
// ============================================================
interface TlbArray;
    // TLBRD: read TLB entry at given index
    method TlbReadResult readEntry(Bit#(5) index);

    // TLBSRCH: search for matching entry (pipelined)
    method Action searchReq(Data tlbehi, Data asid);
    method Bool   searchRespValid;
    method ActionValue#(Data) searchResp;

    // TLBWR: write to TLB at specified index
    method Action writeEntry(Data tlbidx, Data tlbehi, Data tlbelo0, Data tlbelo1, Data asid);

    // TLBFILL: write to TLB at random index
    method Action fillEntry(Data tlbidx, Data tlbehi, Data tlbelo0, Data tlbelo1, Data asid);

    // INVTLB: invalidate TLB entries
    method Action invtlb(Bit#(5) op, Data asidVal, Data vaVal);
endinterface

// ============================================================
// Helper functions: decode CSR fields into internal TLB entry
// ============================================================
function TlbEntry decodeTlbEntry(Data tlbehi, Data tlbelo0, Data tlbelo1, Data asid);
    Bit#(1) g0 = tlbelo0[`CSR_TLBELO_G];
    Bit#(1) g1 = tlbelo1[`CSR_TLBELO_G];

    return TlbEntry {
        e:    True,
        asid: asid[`CSR_ASID_ASID],
        g:    (g0 == 1'b1 && g1 == 1'b1),
        ps:   12,
        vppn: tlbehi[`CSR_TLBEHI_VPPN],
        v0:   unpack(tlbelo0[`CSR_TLBELO_V]),
        d0:   unpack(tlbelo0[`CSR_TLBELO_D]),
        mat0: tlbelo0[`CSR_TLBELO_MAT],
        plv0: tlbelo0[`CSR_TLBELO_PLV],
        ppn0: tlbelo0[`CSR_TLBELO_PPN],
        v1:   unpack(tlbelo1[`CSR_TLBELO_V]),
        d1:   unpack(tlbelo1[`CSR_TLBELO_D]),
        mat1: tlbelo1[`CSR_TLBELO_MAT],
        plv1: tlbelo1[`CSR_TLBELO_PLV],
        ppn1: tlbelo1[`CSR_TLBELO_PPN]
    };
endfunction

// Encode internal TLB entry back into CSR format
function Data encodeTlbEhi(TlbEntry e);
    return { e.vppn, 13'b0 };
endfunction

function Data encodeTlbElo0(TlbEntry e);
    // TLBELO0 format [31:0]:
    //   [31:28] = 0 (reserved)
    //   [27:8]  = PPN0
    //   [7]     = 0 (reserved)
    //   [6]     = G
    //   [5:4]   = MAT0
    //   [3:2]   = PLV0
    //   [1]     = D0
    //   [0]     = V0
    return { 4'b0, e.ppn0, 1'b0, pack(e.g), e.mat0, e.plv0, pack(e.d0), pack(e.v0) };
endfunction

function Data encodeTlbElo1(TlbEntry e);
    return { 4'b0, e.ppn1, 1'b0, pack(e.g), e.mat1, e.plv1, pack(e.d1), pack(e.v1) };
endfunction

function TlbReadResult encodeTlbReadResult(TlbEntry e);
    return TlbReadResult {
        ne:   !e.e,
        ps:   e.ps,
        ehi:  encodeTlbEhi(e),
        elo0: encodeTlbElo0(e),
        elo1: encodeTlbElo1(e),
        asid: zeroExtend(e.asid)
    };
endfunction

// ============================================================
// Match a TLB entry against the search key
// Returns the search result with hit=True if the entry matches.
// VPPN matching: compare VA[31:PS+1] which maps to VPPN[18:PS-12].
// For PS=12: compare all 19 bits of VPPN.
// For PS=21: compare VPPN[18:9] (upper 10 bits).
// ============================================================
function TlbSearchEntry matchEntry(TlbEntry ent, TlbIndex idx,
                                   Bit#(19) vppn, Bit#(10) asid);
    TlbSearchEntry result = noSearchHit;

    if (ent.e) begin
        Bool asidOk = ent.g || (ent.asid == asid);
        if (asidOk) begin
            Bit#(6) ps = ent.ps;
            Bit#(5) lowBit = truncate(ps - 12);
            Bit#(19) shiftVal = {14'b0, lowBit};
            Bit#(19) mask = ~((19'b1 << shiftVal) - 19'b1);
            Bool vppnMatch = ((ent.vppn & mask) == (vppn & mask));
            if (vppnMatch)
                result = TlbSearchEntry { hit: True, idx: idx, ps: ps };
        end
    end

    return result;
endfunction

// ============================================================
// Pipelined search: log2(N) stages using binary tree reduction
//
// Stage 0 (searchReq): all entries compare in parallel → pipeRegs[0]
// Stage k (rule doSearchPipe): merge pairs from pipeRegs[k-1] → pipeRegs[k]
// After log2(N) stages, the final single result is in searchResult.
// ============================================================

(* synthesize *)
module mkTlb(TlbArray);
    // TLB storage
    Vector#(TlbNumEntries, Reg#(TlbEntry)) entries <- replicateM(mkRegU);

    // Initialize all entries as invalid on first cycle
    Reg#(Bool) initialized <- mkReg(False);
    rule doInit(!initialized);
        for (Integer i = 0; i < valueOf(TlbNumEntries); i = i + 1)
            entries[i] <= TlbEntry {
                e: False, asid: 0, g: False, ps: 12, vppn: 0,
                v0: False, d0: False, mat0: 0, plv0: 0, ppn0: 0,
                v1: False, d1: False, mat1: 0, plv1: 0, ppn1: 0
            };
        initialized <= True;
    endrule

    // Pseudo-random replacement counter for TLBFILL
    Reg#(TlbIndex) replaceCnt <- mkReg(0);

    // ========================================================
    // Pipelined search state
    // ========================================================
    // Pipeline registers: one per stage.
    // Each holds a full-width vector; only the lower half is meaningful
    // after each reduction step.
    Vector#(TlbSearchStages, Reg#(Vector#(TlbNumEntries, TlbSearchEntry))) pipeRegs;
    for (Integer k = 0; k < valueOf(TlbSearchStages); k = k + 1)
        pipeRegs[k] <- mkReg(replicate(noSearchHit));

    Reg#(Bool)    searchValid  <- mkReg(False);
    Reg#(Bit#(TlbSearchStages)) searchStage <- mkReg(0);

    // Final search result
    Reg#(Maybe#(Data)) searchResult <- mkReg(tagged Invalid);

    // ========================================================
    // Search pipeline rule: one tree-reduction level per cycle
    // ========================================================
    rule doSearchPipe(searchValid);
        let stage = searchStage;
        Vector#(TlbNumEntries, TlbSearchEntry) cur = pipeRegs[stage];

        // Merge pairs: cur[2i] and cur[2i+1] → pickSearchWinner → next[i]
        Vector#(TlbNumEntries, TlbSearchEntry) next = replicate(noSearchHit);
        for (Integer i = 0; i < valueOf(TlbNumEntries) / 2; i = i + 1)
            next[i] = pickSearchWinner(cur[2*i], cur[2*i + 1]);

        let nextStage = stage + 1;

        if (nextStage < fromInteger(valueOf(TlbSearchStages))) begin
            pipeRegs[nextStage] <= next;
            searchStage <= nextStage;
        end else begin
            // Final result: next[0] is the winner
            let winner = next[0];
            Data result = 0;
            if (winner.hit) begin
                result[`CSR_TLBIDX_INDEX] = zeroExtend(winner.idx);
            end else begin
                result[`CSR_TLBIDX_NE] = 1'b1;
            end
            searchResult <= tagged Valid result;
            searchValid <= False;
        end
    endrule

    // ========================================================
    // Interface methods
    // ========================================================

    // TLBRD: read entry at index (combinational)
    method TlbReadResult readEntry(Bit#(5) index);
        TlbIndex idx = truncate(index);
        TlbEntry ent = entries[idx];
        return encodeTlbReadResult(ent);
    endmethod

    // TLBSRCH: initiate search
    method Action searchReq(Data tlbehi, Data asid) if (!searchValid);
        Bit#(19) vppn = tlbehi[`CSR_TLBEHI_VPPN];
        Bit#(10) asidVal = asid[`CSR_ASID_ASID];

        // Stage 0: all entries compare in parallel
        Vector#(TlbNumEntries, TlbSearchEntry) stage0;
        for (Integer i = 0; i < valueOf(TlbNumEntries); i = i + 1)
            stage0[i] = matchEntry(entries[i], fromInteger(i), vppn, asidVal);

        pipeRegs[0] <= stage0;
        searchValid <= True;
        searchStage <= 0;
        searchResult <= tagged Invalid;
    endmethod

    method Bool searchRespValid;
        return isValid(searchResult);
    endmethod

    method ActionValue#(Data) searchResp if (isValid(searchResult));
        let res = fromMaybe(?, searchResult);
        searchResult <= tagged Invalid;
        return res;
    endmethod

    // TLBWR: write at specified index
    method Action writeEntry(Data tlbidx, Data tlbehi, Data tlbelo0, Data tlbelo1, Data asid);
        TlbIndex idx = truncate(tlbidx[`CSR_TLBIDX_INDEX]);
        TlbEntry ent = decodeTlbEntry(tlbehi, tlbelo0, tlbelo1, asid);
        ent.ps = tlbidx[`CSR_TLBIDX_PS];
        // E = !NE for normal writes
        ent.e = (tlbidx[`CSR_TLBIDX_NE] == 1'b0);
        entries[idx] <= ent;
    endmethod

    // TLBFILL: write at random (round-robin) index
    method Action fillEntry(Data tlbidx, Data tlbehi, Data tlbelo0, Data tlbelo1, Data asid);
        TlbIndex idx = replaceCnt;
        TlbEntry ent = decodeTlbEntry(tlbehi, tlbelo0, tlbelo1, asid);
        ent.ps = tlbidx[`CSR_TLBIDX_PS];
        // TLBFILL always sets E=1 (NE is ignored per spec)
        ent.e = True;
        entries[idx] <= ent;
        replaceCnt <= replaceCnt + 1;
    endmethod

    // INVTLB: invalidate entries
    method Action invtlb(Bit#(5) op, Data asidVal, Data vaVal);
        Bit#(10) invAsid = asidVal[`CSR_ASID_ASID];
        Bit#(19) invVppn = vaVal[31:13];

        TlbEntry emptyEntry = TlbEntry {
            e: False, asid: 0, g: False, ps: 12, vppn: 0,
            v0: False, d0: False, mat0: 0, plv0: 0, ppn0: 0,
            v1: False, d1: False, mat1: 0, plv1: 0, ppn1: 0
        };

        for (Integer i = 0; i < valueOf(TlbNumEntries); i = i + 1) begin
            TlbEntry ent = entries[i];
            Bool doInvalidate = False;

            case (op)
                5'd0: begin
                    // Invalidate all entries (regardless of E bit)
                    doInvalidate = True;
                end
                5'd1: begin
                    // Invalidate all G=1 entries
                    doInvalidate = ent.e && ent.g;
                end
                5'd2: begin
                    // Invalidate all G=0 entries
                    doInvalidate = ent.e && !ent.g;
                end
                5'd3: begin
                    // Invalidate G=0 and ASID match
                    doInvalidate = ent.e && !ent.g && (ent.asid == invAsid);
                end
                5'd4: begin
                    // Invalidate G=0 and ASID match and VPPN match
                    Bool asidMatch = (ent.asid == invAsid);
                    Bool vppnMatch = (ent.vppn == invVppn);
                    doInvalidate = ent.e && !ent.g && asidMatch && vppnMatch;
                end
                5'd5: begin
                    // Invalidate G=1 or ASID match
                    doInvalidate = ent.e && (ent.g || (ent.asid == invAsid));
                end
                default: doInvalidate = False;
            endcase

            if (doInvalidate)
                entries[i] <= emptyEntry;
        end
    endmethod
endmodule
