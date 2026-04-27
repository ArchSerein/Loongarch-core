import Types::*;
import ProcTypes::*;
import Vector::*;
import Fifo::*;
`include "CsrAddr.bsv"
`include "Autoconf.bsv"

// ============================================================
// Configurable parameters
// ============================================================
typedef `CONFIG_TLB_ENTRIES TlbNumEntries;
typedef TLog#(TlbNumEntries) TlbIndexSz;
typedef Bit#(TlbIndexSz)     TlbIndex;

typedef 8 TlbCompareEntries;
typedef TDiv#(TlbNumEntries, TlbCompareEntries) TlbCompareChunks;
typedef TAdd#(TLog#(TlbCompareChunks), 1) TlbCompareCntSz;
typedef Bit#(TlbCompareCntSz) TlbCompareCnt;

// ============================================================
// Data Structures
// ============================================================
typedef struct {
  Bool     e;
  Bit#(10) asid;
  Bool     g;
  Bit#(6)  ps;
  Bit#(19) vppn;
  Bool     v0;
  Bool     d0;
  Bit#(2)  mat0;
  Bit#(2)  plv0;
  Bit#(20) ppn0;
  Bool     v1;
  Bool     d1;
  Bit#(2)  mat1;
  Bit#(2)  plv1;
  Bit#(20) ppn1;
} TlbEntry deriving(Bits, Eq);

TlbEntry emptyEntry = TlbEntry {
  e: False, asid: 0, g: False, ps: 12, vppn: 0,
  v0: False, d0: False, mat0: 0, plv0: 0, ppn0: 0,
  v1: False, d1: False, mat1: 0, plv1: 0, ppn1: 0
};

typedef struct {
  Bool    ne;
  Bit#(6) ps;
  Data    ehi;
  Data    elo0;
  Data    elo1;
  Data    asid;
} TlbReadResult deriving(Bits, Eq);

typedef struct {
  Bool     found;
  Bit#(6)  ps;
  Bool     v;
  Bool     d;
  Bit#(2)  mat;
  Bit#(2)  plv;
  Bit#(20) ppn;
} TlbLookupResult deriving(Bits, Eq);

function TlbLookupResult noTlbLookup;
  return TlbLookupResult { found: False, ps: 0, v: False, d: False, mat: 0, plv: 0, ppn: 0 };
endfunction

typedef struct {
  Bool     hit;
  TlbIndex idx;
  Bit#(6)  ps;
} TlbSearchEntry deriving(Bits, Eq);

function TlbSearchEntry noSearchHit;
  return TlbSearchEntry { hit: False, idx: 0, ps: 0 };
endfunction

typedef enum {
  TlbOpRead,
  TlbOpSearch,
  TlbOpWrite,
  TlbOpFill,
  TlbOpInv
} TlbOp deriving(Bits, Eq);

typedef struct {
  TlbOp   op;
  Data    tlbidx;
  Bit#(5) invOp;
  Data    ehi;
  Data    elo0;
  Data    elo1;
  Data    asid;
  Data    va;
} TlbReq deriving(Bits, Eq);

typedef struct {
  Addr     va;
  Bit#(10) asidVal;
  Bit#(19) vppn;
} LookupCtx deriving(Bits, Eq);

typedef enum {
  ReqScanSearch,
  ReqScanInv
} ReqScanKind deriving(Bits, Eq);

typedef struct {
  ReqScanKind kind;
  Bit#(19)    searchVppn;
  Bit#(10)    searchAsid;
  Bit#(5)     invOp;
  Bit#(10)    invAsid;
  Bit#(19)    invVppn;
} ReqScanCtx deriving(Bits, Eq);

// ============================================================
// Interface (分为 Fetch 和 Data 两组并行接口)
// ============================================================
interface TlbArray;
  method Action req(TlbReq r);
  method ActionValue#(TlbReadResult) resp();

  // Instruction Fetch 接口
  method Action fetchLookupReq(Addr va, Data asid);
  method ActionValue#(TlbLookupResult) fetchLookupResp();

  // Memory Data 接口
  method Action dataLookupReq(Addr va, Data asid);
  method ActionValue#(TlbLookupResult) dataLookupResp();

  method Action squashFetchLookup();
  method Action squashDataLookup();
endinterface

// ============================================================
// Helper functions
// ============================================================
function TlbEntry decodeTlbEntry(Data tlbehi, Data tlbelo0, Data tlbelo1, Data asid);
  Bit#(1) g0 = tlbelo0[`CSR_TLBELO_G];
  Bit#(1) g1 = tlbelo1[`CSR_TLBELO_G];
  return TlbEntry {
    e:    True, asid: asid[`CSR_ASID_ASID], g: (g0 == 1'b1 && g1 == 1'b1),
    ps:   12, vppn: tlbehi[`CSR_TLBEHI_VPPN],
    v0:   unpack(tlbelo0[`CSR_TLBELO_V]), d0:   unpack(tlbelo0[`CSR_TLBELO_D]),
    mat0: tlbelo0[`CSR_TLBELO_MAT], plv0: tlbelo0[`CSR_TLBELO_PLV], ppn0: tlbelo0[`CSR_TLBELO_PPN],
    v1:   unpack(tlbelo1[`CSR_TLBELO_V]), d1:   unpack(tlbelo1[`CSR_TLBELO_D]),
    mat1: tlbelo1[`CSR_TLBELO_MAT], plv1: tlbelo1[`CSR_TLBELO_PLV], ppn1: tlbelo1[`CSR_TLBELO_PPN]
  };
endfunction

function Data encodeTlbEhi(TlbEntry e); return { e.vppn, 13'b0 }; endfunction
function Data encodeTlbElo0(TlbEntry e); return { 4'b0, e.ppn0, 1'b0, pack(e.g), e.mat0, e.plv0, pack(e.d0), pack(e.v0) }; endfunction
function Data encodeTlbElo1(TlbEntry e); return { 4'b0, e.ppn1, 1'b0, pack(e.g), e.mat1, e.plv1, pack(e.d1), pack(e.v1) }; endfunction
function TlbReadResult encodeTlbReadResult(TlbEntry e);
  return TlbReadResult { ne: !e.e, ps: e.ps, ehi: encodeTlbEhi(e), elo0: encodeTlbElo0(e), elo1: encodeTlbElo1(e), asid: zeroExtend(e.asid) };
endfunction

function Bool tlbVppnMatch(Bit#(6) ps, Bit#(19) entVppn, Bit#(19) keyVppn);
  Bit#(10) entVppn4m = truncate(entVppn >> 9);
  Bit#(10) keyVppn4m = truncate(keyVppn >> 9);
  return (ps == 21) ? (entVppn4m == keyVppn4m) : (entVppn == keyVppn);
endfunction

function Bool tlbOddPage(Bit#(6) ps, Addr va);
  return (ps == 21) ? (va[21] == 1'b1) : (va[12] == 1'b1);
endfunction

function TlbIndex tlbChunkBase(TlbCompareCnt cnt);
  TlbIndex widened = zeroExtend(cnt);
  return widened << 3;
endfunction

function TlbLookupResult matchLookupEntry(TlbEntry ent, Addr va, Bit#(19) vppn, Bit#(10) asidVal);
  TlbLookupResult result = noTlbLookup;
  Bool asidOk = ent.g || (ent.asid == asidVal);
  Bool hit = ent.e && asidOk && tlbVppnMatch(ent.ps, ent.vppn, vppn);
  if (hit) begin
    Bool oddPage = tlbOddPage(ent.ps, va);
    result = TlbLookupResult {
      found: True, ps: ent.ps,
      v: oddPage ? ent.v1 : ent.v0, d: oddPage ? ent.d1 : ent.d0,
      mat: oddPage ? ent.mat1 : ent.mat0, plv: oddPage ? ent.plv1 : ent.plv0, ppn: oddPage ? ent.ppn1 : ent.ppn0
    };
  end
  return result;
endfunction

function TlbLookupResult mergeLookupHit(TlbLookupResult oldHit, TlbLookupResult newHit);
  return oldHit.found ? oldHit : newHit;
endfunction

function TlbSearchEntry matchSearchEntry(TlbEntry ent, TlbIndex idx, Bit#(19) vppn, Bit#(10) asidVal);
  Bool asidOk = ent.g || (ent.asid == asidVal);
  Bool hit = ent.e && asidOk && tlbVppnMatch(ent.ps, ent.vppn, vppn);
  return hit ? TlbSearchEntry { hit: True, idx: idx, ps: ent.ps } : noSearchHit;
endfunction

function TlbSearchEntry mergeSearchHit(TlbSearchEntry oldHit, TlbSearchEntry newHit);
  return oldHit.hit ? oldHit : newHit;
endfunction

function Bool shouldInvalidateEntry(TlbEntry ent, Bit#(5) invOp, Bit#(10) invAsid, Bit#(19) invVppn);
  Bool doInv = False;
  case (invOp)
    5'h0, 5'h1: doInv = True;
    5'h2: doInv = ent.e && ent.g;
    5'h3: doInv = ent.e && !ent.g;
    5'h4: doInv = ent.e && !ent.g && (ent.asid == invAsid);
    5'h5: doInv = ent.e && !ent.g && (ent.asid == invAsid) && tlbVppnMatch(ent.ps, ent.vppn, invVppn);
    5'h6: doInv = ent.e && (ent.g || (ent.asid == invAsid)) && tlbVppnMatch(ent.ps, ent.vppn, invVppn);
    default: doInv = False;
  endcase
  return doInv;
endfunction

// ============================================================
// Module Definition
// ============================================================
(* synthesize *)
module mkTlb(TlbArray);

  Vector#(TlbNumEntries, Reg#(TlbEntry)) entries <- replicateM(mkReg(emptyEntry));
  Reg#(TlbIndex) replaceCnt <- mkReg(0);

  // 维护指令队列
  Fifo#(2, TlbReq) reqFifo <- mkCFFifo;
  Fifo#(2, TlbReadResult) respFifo <- mkCFFifo;

  // Fetch 专用独立队列
  Fifo#(2, Tuple2#(Addr, Data)) fetchReqFifo <- mkCFFifo;
  Fifo#(2, TlbLookupResult) fetchRespFifo <- mkCFFifo;

  // Data 专用独立队列
  Fifo#(2, Tuple2#(Addr, Data)) dataReqFifo <- mkCFFifo;
  Fifo#(2, TlbLookupResult) dataRespFifo <- mkCFFifo;

  // Three scan counters: 0 means idle; non-zero values select the next 8-entry chunk.
  Reg#(TlbCompareCnt) fetchCnt <- mkReg(0);
  Reg#(LookupCtx) fetchCtx <- mkRegU;
  Reg#(TlbLookupResult) fetchHit <- mkReg(noTlbLookup);

  Reg#(TlbCompareCnt) dataCnt <- mkReg(0);
  Reg#(LookupCtx) dataCtx <- mkRegU;
  Reg#(TlbLookupResult) dataHit <- mkReg(noTlbLookup);

  Reg#(TlbCompareCnt) reqCnt <- mkReg(0);
  Reg#(ReqScanCtx) reqScanCtx <- mkRegU;
  Reg#(TlbSearchEntry) reqSearchHit <- mkReg(noSearchHit);

  // ============================================================
  // Fetch Lookup Scan
  // ============================================================
  rule doFetchLookupPipeline (fetchRespFifo.notFull && (fetchCnt != 0 || fetchReqFifo.notEmpty));
    TlbCompareCnt curCnt = fetchCnt;
    LookupCtx ctx = fetchCtx;
    TlbLookupResult oldHit = fetchHit;

    if (fetchCnt == 0) begin
      let reqTuple = fetchReqFifo.first;
      fetchReqFifo.deq;
      ctx = LookupCtx { va: tpl_1(reqTuple), asidVal: tpl_2(reqTuple)[`CSR_ASID_ASID], vppn: tpl_1(reqTuple)[`CSR_TLBEHI_VPPN] };
      oldHit = noTlbLookup;
    end else begin
      curCnt = fetchCnt;
    end

    TlbLookupResult chunkHit = noTlbLookup;
    TlbIndex baseIdx = tlbChunkBase(curCnt);
    for (Integer i = 0; i < valueOf(TlbCompareEntries); i = i + 1) begin
      TlbIndex idx = baseIdx + fromInteger(i);
      chunkHit = mergeLookupHit(chunkHit, matchLookupEntry(entries[idx], ctx.va, ctx.vppn, ctx.asidVal));
    end

    TlbLookupResult nextHit = mergeLookupHit(oldHit, chunkHit);
    if (curCnt == fromInteger(valueOf(TlbCompareChunks) - 1)) begin
      fetchRespFifo.enq(nextHit);
      fetchCnt <= 0;
    end else begin
      fetchCtx <= ctx;
      fetchHit <= nextHit;
      fetchCnt <= curCnt + 1;
    end
  endrule

  // ============================================================
  // Data Lookup Scan
  // ============================================================
  rule doDataLookupPipeline (dataRespFifo.notFull && (dataCnt != 0 || dataReqFifo.notEmpty));
    TlbCompareCnt curCnt = dataCnt;
    LookupCtx ctx = dataCtx;
    TlbLookupResult oldHit = dataHit;

    if (dataCnt == 0) begin
      let reqTuple = dataReqFifo.first;
      dataReqFifo.deq;
      ctx = LookupCtx { va: tpl_1(reqTuple), asidVal: tpl_2(reqTuple)[`CSR_ASID_ASID], vppn: tpl_1(reqTuple)[`CSR_TLBEHI_VPPN] };
      oldHit = noTlbLookup;
    end else begin
      curCnt = dataCnt;
    end

    TlbLookupResult chunkHit = noTlbLookup;
    TlbIndex baseIdx = tlbChunkBase(curCnt);
    for (Integer i = 0; i < valueOf(TlbCompareEntries); i = i + 1) begin
      TlbIndex idx = baseIdx + fromInteger(i);
      chunkHit = mergeLookupHit(chunkHit, matchLookupEntry(entries[idx], ctx.va, ctx.vppn, ctx.asidVal));
    end

    TlbLookupResult nextHit = mergeLookupHit(oldHit, chunkHit);
    if (curCnt == fromInteger(valueOf(TlbCompareChunks) - 1)) begin
      dataRespFifo.enq(nextHit);
      dataCnt <= 0;
    end else begin
      dataCtx <= ctx;
      dataHit <= nextHit;
      dataCnt <= curCnt + 1;
    end
  endrule

  // ============================================================
  // Maintenance Scan
  // ============================================================
  rule doReqPipeline (respFifo.notFull && (reqCnt != 0 || reqFifo.notEmpty));
    TlbCompareCnt curCnt = reqCnt;
    ReqScanCtx scanCtx = reqScanCtx;
    TlbSearchEntry oldSearchHit = reqSearchHit;

    if (reqCnt != 0) begin
      TlbIndex baseIdx = tlbChunkBase(curCnt);
      if (scanCtx.kind == ReqScanSearch) begin
        TlbSearchEntry chunkHit = noSearchHit;
        for (Integer i = 0; i < valueOf(TlbCompareEntries); i = i + 1) begin
          TlbIndex idx = baseIdx + fromInteger(i);
          chunkHit = mergeSearchHit(chunkHit, matchSearchEntry(entries[idx], idx, scanCtx.searchVppn, scanCtx.searchAsid));
        end

        TlbSearchEntry nextHit = mergeSearchHit(oldSearchHit, chunkHit);
        if (curCnt == fromInteger(valueOf(TlbCompareChunks) - 1)) begin
          TlbReadResult res = encodeTlbReadResult(emptyEntry);
          res.ne = !nextHit.hit;
          res.ps = nextHit.ps;
          if (nextHit.hit) res.ehi[`CSR_TLBIDX_INDEX] = zeroExtend(nextHit.idx);
          respFifo.enq(res);
          reqCnt <= 0;
        end else begin
          reqSearchHit <= nextHit;
          reqCnt <= curCnt + 1;
        end
      end else begin
        for (Integer i = 0; i < valueOf(TlbCompareEntries); i = i + 1) begin
          TlbIndex idx = baseIdx + fromInteger(i);
          if (shouldInvalidateEntry(entries[idx], scanCtx.invOp, scanCtx.invAsid, scanCtx.invVppn)) entries[idx] <= emptyEntry;
        end

        if (curCnt == fromInteger(valueOf(TlbCompareChunks) - 1)) begin
          respFifo.enq(encodeTlbReadResult(emptyEntry));
          reqCnt <= 0;
        end else begin
          reqCnt <= curCnt + 1;
        end
      end
    end else begin
      let r = reqFifo.first;
      reqFifo.deq;
      TlbReadResult dummyRes = encodeTlbReadResult(emptyEntry);
      
      if (r.op == TlbOpSearch) begin
        Bit#(19) vppn = r.ehi[`CSR_TLBEHI_VPPN];
        Bit#(10) asidVal = r.asid[`CSR_ASID_ASID];

        TlbSearchEntry chunkHit = noSearchHit;
        TlbIndex baseIdx = tlbChunkBase(0);
        for (Integer i = 0; i < valueOf(TlbCompareEntries); i = i + 1) begin
          TlbIndex idx = baseIdx + fromInteger(i);
          chunkHit = mergeSearchHit(chunkHit, matchSearchEntry(entries[idx], idx, vppn, asidVal));
        end

        if (fromInteger(valueOf(TlbCompareChunks) - 1) == 0) begin
          TlbReadResult res = dummyRes;
          res.ne = !chunkHit.hit;
          res.ps = chunkHit.ps;
          if (chunkHit.hit) res.ehi[`CSR_TLBIDX_INDEX] = zeroExtend(chunkHit.idx);
          respFifo.enq(res);
        end else begin
          reqScanCtx <= ReqScanCtx {
            kind: ReqScanSearch, searchVppn: vppn, searchAsid: asidVal,
            invOp: 0, invAsid: 0, invVppn: 0
          };
          reqSearchHit <= chunkHit;
          reqCnt <= 1;
        end
      end 
      else if (r.op == TlbOpRead) begin
        TlbIndex idx = truncate(r.tlbidx[`CSR_TLBIDX_INDEX]);
        let res = encodeTlbReadResult(entries[idx]);
        respFifo.enq(res);
      end 
      else if (r.op == TlbOpWrite || r.op == TlbOpFill) begin
        TlbIndex idx = (r.op == TlbOpFill) ? replaceCnt : truncate(r.tlbidx[`CSR_TLBIDX_INDEX]);
        TlbEntry ent = decodeTlbEntry(r.ehi, r.elo0, r.elo1, r.asid);
        ent.ps = r.tlbidx[`CSR_TLBIDX_PS];
        ent.e = (r.tlbidx[`CSR_TLBIDX_NE] == 1'b0);
        
        entries[idx] <= ent;
        if (r.op == TlbOpFill) replaceCnt <= replaceCnt + 1;
        
        TlbReadResult res = dummyRes;
        res.ehi[`CSR_TLBIDX_INDEX] = zeroExtend(idx);
        respFifo.enq(res);
      end 
      else if (r.op == TlbOpInv) begin
        Bit#(10) invAsid = r.asid[`CSR_ASID_ASID];
        Bit#(19) invVppn = r.va[31:13];
        
        TlbIndex baseIdx = tlbChunkBase(0);
        for (Integer i = 0; i < valueOf(TlbCompareEntries); i = i + 1) begin
          TlbIndex idx = baseIdx + fromInteger(i);
          if (shouldInvalidateEntry(entries[idx], r.invOp, invAsid, invVppn)) entries[idx] <= emptyEntry;
        end

        if (fromInteger(valueOf(TlbCompareChunks) - 1) == 0) begin
          respFifo.enq(dummyRes);
        end else begin
          reqScanCtx <= ReqScanCtx {
            kind: ReqScanInv, searchVppn: 0, searchAsid: 0,
            invOp: r.invOp, invAsid: invAsid, invVppn: invVppn
          };
          reqCnt <= 1;
        end
      end
    end
  endrule

  // ============================================================
  // Interface Methods
  // ============================================================
  method Action req(TlbReq r);
    reqFifo.enq(r);
  endmethod

  method ActionValue#(TlbReadResult) resp();
    let res = respFifo.first;
    respFifo.deq;
    return res;
  endmethod

  // --- Fetch Interface ---
  method Action fetchLookupReq(Addr va, Data asid);
    fetchReqFifo.enq(tuple2(va, asid));
  endmethod

  method ActionValue#(TlbLookupResult) fetchLookupResp();
    let res = fetchRespFifo.first;
    fetchRespFifo.deq;
    return res;
  endmethod

  // --- Data Interface ---
  method Action dataLookupReq(Addr va, Data asid);
    dataReqFifo.enq(tuple2(va, asid));
  endmethod

  method ActionValue#(TlbLookupResult) dataLookupResp();
    let res = dataRespFifo.first;
    dataRespFifo.deq;
    return res;
  endmethod

  method Action squashFetchLookup();
    fetchReqFifo.clear();
    fetchRespFifo.clear();
    fetchCnt <= 0;
    fetchHit <= noTlbLookup;
  endmethod

  method Action squashDataLookup();
    dataReqFifo.clear();
    dataRespFifo.clear();
    dataCnt <= 0;
    dataHit <= noTlbLookup;
  endmethod

endmodule
