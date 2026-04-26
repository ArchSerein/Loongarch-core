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

// Number of reduction stages for pipelines = log2(TLB_ENTRIES)
typedef TLog#(TlbNumEntries) TlbSearchStages;

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

typedef enum {
  OpTypeSearch,
  OpTypeDirect,
  OpTypeInv
} PipeOpType deriving(Bits, Eq);

typedef struct {
  PipeOpType                             opType;
  TlbReadResult                          directRes;
  Vector#(TlbNumEntries, TlbSearchEntry) searchVec;
  Bit#(5)                                invOp;
  Bit#(10)                               invAsid;
  Bit#(19)                               invVppn;
} ReqPipeData deriving(Bits, Eq);

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

function Vector#(TlbNumEntries, TlbSearchEntry) reduceSearchEntries(Vector#(TlbNumEntries, TlbSearchEntry) cur);
  Vector#(TlbNumEntries, TlbSearchEntry) next = replicate(noSearchHit);
  for (Integer i = 0; i < valueOf(TlbNumEntries) / 2; i = i + 1)
    next[i] = cur[2*i].hit ? cur[2*i] : cur[2*i + 1];
  return next;
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

function Vector#(TlbNumEntries, TlbLookupResult) reduceLookupEntries(Vector#(TlbNumEntries, TlbLookupResult) cur);
  Vector#(TlbNumEntries, TlbLookupResult) next = replicate(noTlbLookup);
  for (Integer i = 0; i < valueOf(TlbNumEntries) / 2; i = i + 1)
    next[i] = cur[2*i].found ? cur[2*i] : cur[2*i + 1];
  return next;
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

  // 各自独立的流水线寄存器
  Vector#(TlbSearchStages, Reg#(Maybe#(ReqPipeData))) reqPipe <- replicateM(mkReg(tagged Invalid));
  Vector#(TlbSearchStages, Reg#(Maybe#(Vector#(TlbNumEntries, TlbLookupResult)))) fetchPipe <- replicateM(mkReg(tagged Invalid));
  Vector#(TlbSearchStages, Reg#(Maybe#(Vector#(TlbNumEntries, TlbLookupResult)))) dataPipe <- replicateM(mkReg(tagged Invalid));

  // ============================================================
  // Fetch Lookup Pipeline
  // ============================================================
  rule doFetchLookupPipeline (fetchRespFifo.notFull);
    if (fetchPipe[valueOf(TlbSearchStages)-1] matches tagged Valid .vec) begin
      fetchRespFifo.enq(reduceLookupEntries(vec)[0]);
    end

    for (Integer i = 1; i < valueOf(TlbSearchStages); i = i + 1) begin
      if (fetchPipe[i-1] matches tagged Valid .vec) begin
        fetchPipe[i] <= tagged Valid (reduceLookupEntries(vec));
      end else begin
        fetchPipe[i] <= tagged Invalid;
      end
    end

    if (fetchReqFifo.notEmpty) begin
      let reqTuple = fetchReqFifo.first;
      fetchReqFifo.deq;
      Addr va = tpl_1(reqTuple);
      Data asid = tpl_2(reqTuple);
      Bit#(10) asidVal = asid[`CSR_ASID_ASID];
      Bit#(19) vppn = va[`CSR_TLBEHI_VPPN];

      Vector#(TlbNumEntries, TlbLookupResult) stage0;
      for (Integer i = 0; i < valueOf(TlbNumEntries); i = i + 1)
        stage0[i] = matchLookupEntry(entries[i], va, vppn, asidVal);
      
      fetchPipe[0] <= tagged Valid stage0;
    end else begin
      fetchPipe[0] <= tagged Invalid;
    end
  endrule

  // ============================================================
  // Data Lookup Pipeline
  // ============================================================
  rule doDataLookupPipeline (dataRespFifo.notFull);
    if (dataPipe[valueOf(TlbSearchStages)-1] matches tagged Valid .vec) begin
      dataRespFifo.enq(reduceLookupEntries(vec)[0]);
    end

    for (Integer i = 1; i < valueOf(TlbSearchStages); i = i + 1) begin
      if (dataPipe[i-1] matches tagged Valid .vec) begin
        dataPipe[i] <= tagged Valid (reduceLookupEntries(vec));
      end else begin
        dataPipe[i] <= tagged Invalid;
      end
    end

    if (dataReqFifo.notEmpty) begin
      let reqTuple = dataReqFifo.first;
      dataReqFifo.deq;
      Addr va = tpl_1(reqTuple);
      Data asid = tpl_2(reqTuple);
      Bit#(10) asidVal = asid[`CSR_ASID_ASID];
      Bit#(19) vppn = va[`CSR_TLBEHI_VPPN];

      Vector#(TlbNumEntries, TlbLookupResult) stage0;
      for (Integer i = 0; i < valueOf(TlbNumEntries); i = i + 1)
        stage0[i] = matchLookupEntry(entries[i], va, vppn, asidVal);
      
      dataPipe[0] <= tagged Valid stage0;
    end else begin
      dataPipe[0] <= tagged Invalid;
    end
  endrule

  // ============================================================
  // Maintenance Pipeline (Pipelined spatial unrolling for InvTLB)
  // ============================================================
  rule doReqPipeline (respFifo.notFull);
    Integer totalChunks = valueOf(TlbSearchStages);
    
    // 中间收集器：统一收集当前周期内产生的所有写操作
    Vector#(TlbNumEntries, Maybe#(TlbEntry)) entriesNext = replicate(tagged Invalid);

    // --- Final Stage ---
    if (reqPipe[valueOf(TlbSearchStages)-1] matches tagged Valid .pipeData) begin
      if (pipeData.opType == OpTypeSearch) begin
        let winner = reduceSearchEntries(pipeData.searchVec)[0];
        TlbReadResult res = encodeTlbReadResult(emptyEntry);
        res.ne = !winner.hit;
        res.ps = winner.ps;
        if (winner.hit) res.ehi[`CSR_TLBIDX_INDEX] = zeroExtend(winner.idx);
        respFifo.enq(res);
      end else begin
        respFifo.enq(pipeData.directRes);
      end
    end

    // --- Intermediate Stages 1 to S-1 ---
    for (Integer i = 1; i < valueOf(TlbSearchStages); i = i + 1) begin
      if (reqPipe[i-1] matches tagged Valid .pipeData) begin
        ReqPipeData nextData = pipeData;
        
        if (pipeData.opType == OpTypeSearch) begin
          nextData.searchVec = reduceSearchEntries(pipeData.searchVec);
        end 
        else if (pipeData.opType == OpTypeInv) begin
          // 计算当前流水级负责清空的表项区间
          Integer startIdx = (i * valueOf(TlbNumEntries)) / totalChunks;
          Integer endIdx   = ((i + 1) * valueOf(TlbNumEntries)) / totalChunks;
          for (Integer j = startIdx; j < endIdx; j = j + 1) begin
            TlbEntry ent = entries[j];
            Bool doInv = False;
            case (pipeData.invOp)
              5'h0, 5'h1: doInv = True;
              5'h2: doInv = ent.e && ent.g;
              5'h3: doInv = ent.e && !ent.g;
              5'h4: doInv = ent.e && !ent.g && (ent.asid == pipeData.invAsid);
              5'h5: doInv = ent.e && !ent.g && (ent.asid == pipeData.invAsid) && tlbVppnMatch(ent.ps, ent.vppn, pipeData.invVppn);
              5'h6: doInv = ent.e && (ent.g || (ent.asid == pipeData.invAsid)) && tlbVppnMatch(ent.ps, ent.vppn, pipeData.invVppn);
            endcase
            if (doInv) entriesNext[j] = tagged Valid emptyEntry;
          end
        end
        reqPipe[i] <= tagged Valid nextData;
      end else begin
        reqPipe[i] <= tagged Invalid;
      end
    end

    // --- Stage 0 Entry ---
    if (reqFifo.notEmpty) begin
      let r = reqFifo.first;
      reqFifo.deq;
      TlbReadResult dummyRes = encodeTlbReadResult(emptyEntry);
      Vector#(TlbNumEntries, TlbSearchEntry) dummyVec = replicate(noSearchHit);
      
      if (r.op == TlbOpSearch) begin
        Bit#(19) vppn = r.ehi[`CSR_TLBEHI_VPPN];
        Bit#(10) asidVal = r.asid[`CSR_ASID_ASID];
        Vector#(TlbNumEntries, TlbSearchEntry) stage0 = dummyVec;
        for (Integer j = 0; j < valueOf(TlbNumEntries); j = j + 1) begin
          TlbEntry ent = entries[j];
          Bool asidOk = ent.g || (ent.asid == asidVal);
          Bool hit = ent.e && asidOk && tlbVppnMatch(ent.ps, ent.vppn, vppn);
          stage0[j] = hit ? TlbSearchEntry { hit: True, idx: fromInteger(j), ps: ent.ps } : noSearchHit;
        end
        reqPipe[0] <= tagged Valid ReqPipeData { opType: OpTypeSearch, directRes: dummyRes, searchVec: stage0, invOp: 0, invAsid: 0, invVppn: 0 };
      end 
      else if (r.op == TlbOpRead) begin
        TlbIndex idx = truncate(r.tlbidx[`CSR_TLBIDX_INDEX]);
        let res = encodeTlbReadResult(entries[idx]);
        reqPipe[0] <= tagged Valid ReqPipeData { opType: OpTypeDirect, directRes: res, searchVec: dummyVec, invOp: 0, invAsid: 0, invVppn: 0 };
      end 
      else if (r.op == TlbOpWrite || r.op == TlbOpFill) begin
        TlbIndex idx = (r.op == TlbOpFill) ? replaceCnt : truncate(r.tlbidx[`CSR_TLBIDX_INDEX]);
        TlbEntry ent = decodeTlbEntry(r.ehi, r.elo0, r.elo1, r.asid);
        ent.ps = r.tlbidx[`CSR_TLBIDX_PS];
        ent.e = (r.tlbidx[`CSR_TLBIDX_NE] == 1'b0);
        
        entriesNext[idx] = tagged Valid ent;
        if (r.op == TlbOpFill) replaceCnt <= replaceCnt + 1;
        
        TlbReadResult res = dummyRes;
        res.ehi[`CSR_TLBIDX_INDEX] = zeroExtend(idx);
        reqPipe[0] <= tagged Valid ReqPipeData { opType: OpTypeDirect, directRes: res, searchVec: dummyVec, invOp: 0, invAsid: 0, invVppn: 0 };
      end 
      else if (r.op == TlbOpInv) begin
        Bit#(10) invAsid = r.asid[`CSR_ASID_ASID];
        Bit#(19) invVppn = r.va[31:13];
        
        Integer startIdx = 0;
        Integer endIdx   = (1 * valueOf(TlbNumEntries)) / totalChunks;
        for (Integer j = startIdx; j < endIdx; j = j + 1) begin
          TlbEntry ent = entries[j];
          Bool doInv = False;
          case (r.invOp)
            5'h0, 5'h1: doInv = True;
            5'h2: doInv = ent.e && ent.g;
            5'h3: doInv = ent.e && !ent.g;
            5'h4: doInv = ent.e && !ent.g && (ent.asid == invAsid);
            5'h5: doInv = ent.e && !ent.g && (ent.asid == invAsid) && tlbVppnMatch(ent.ps, ent.vppn, invVppn);
            5'h6: doInv = ent.e && (ent.g || (ent.asid == invAsid)) && tlbVppnMatch(ent.ps, ent.vppn, invVppn);
          endcase
          if (doInv) entriesNext[j] = tagged Valid emptyEntry;
        end
        
        reqPipe[0] <= tagged Valid ReqPipeData { opType: OpTypeInv, directRes: dummyRes, searchVec: dummyVec, invOp: r.invOp, invAsid: invAsid, invVppn: invVppn };
      end
    end else begin
      reqPipe[0] <= tagged Invalid;
    end

    // --- 应用到物理寄存器 ---
    for (Integer i = 0; i < valueOf(TlbNumEntries); i = i + 1) begin
      if (entriesNext[i] matches tagged Valid .newEnt) begin
        entries[i] <= newEnt;
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

endmodule
