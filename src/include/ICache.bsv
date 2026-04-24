import Types::*;
import ProcTypes::*;
import AxiTypes::*;
import Fifo::*;
import Vector::*;
`include "Autoconf.bsv"

// ============================================================
// Configurable parameters (values provided by Kconfig -D flags)
// ============================================================
typedef `CONFIG_ICACHE_SETS       ICacheSets;      // number of sets
typedef `CONFIG_ICACHE_WAYS       ICacheWays;      // set associativity
typedef `CONFIG_ICACHE_LINE_WORDS ICacheLineWords; // words per cache line

// ============================================================
// Derived types
// ============================================================
typedef TLog#(ICacheLineWords)                              ICacheWordSelSz;
typedef TAdd#(ICacheWordSelSz, 2)                           ICacheOffsetSz;
typedef TLog#(ICacheSets)                                   ICacheIndexSz;
typedef TAdd#(ICacheOffsetSz, ICacheIndexSz)                ICacheWaySelOffSz;
typedef TSub#(AddrSz, TAdd#(ICacheIndexSz, ICacheOffsetSz)) ICacheTagSz;

typedef Bit#(ICacheWordSelSz)   ICacheWordSel;
typedef Bit#(ICacheIndexSz)     ICacheIndex;
typedef Bit#(ICacheTagSz)       ICacheTag;
typedef Bit#(TLog#(ICacheWays)) ICacheWayIdx;
typedef Bit#(2)                 ICacheOpType;

typedef Vector#(ICacheLineWords, Data) ICacheLine;
typedef struct {
  Bool        valid;
  ICacheTag   tag;
  Instruction inst;
} ICacheProbeWay deriving (Bits, Eq);
typedef Vector#(ICacheWays, ICacheProbeWay) ICacheProbeResp;

function ICacheProbeResp noICacheProbe;
  return replicate(ICacheProbeWay{valid: False, tag: 0, inst: 0});
endfunction

typedef enum { ICacheMaintInvalidate, ICacheMaintCacop } ICacheMaintKind deriving (Bits, Eq);
typedef struct {
  ICacheMaintKind kind;
  Bit#(5)         op;
  Addr            va;
  Data            ctag;
} ICacheMaintReq deriving (Bits, Eq);

typedef struct {
  Addr        addr;
  Instruction inst;
  Bool        epoch;
} ICacheRefillResp deriving (Bits, Eq);

typedef struct {
  Addr    addr;
  Bool    epoch;
  Bool    useCache;
} ICacheRefillReq deriving (Bits, Eq);

// ============================================================
// Address decomposition
// ============================================================
function ICacheTag     getITag(Addr a)     = truncateLSB(a);
function ICacheIndex   getIIndex(Addr a)   = truncate(a >> valueOf(ICacheOffsetSz));
function ICacheWordSel getIWordSel(Addr a) = truncate(a >> 2);
function ICacheWayIdx  getICacopWaySel(Addr a) = truncate(a);
function Addr getIBlockBase(Addr a);
  Bit#(TSub#(AddrSz, ICacheOffsetSz)) upper = truncateLSB(a);
  Bit#(ICacheOffsetSz) lower = 0;
  return { upper, lower };
endfunction

interface ICache;
  method ICacheProbeResp probe(Addr va);
  method Action refillReq(Addr pa, Bool useCache);
  method ActionValue#(ICacheRefillResp) refillResp;
  method Action commitHit(Addr va, ICacheWayIdx way);
  method Action flush;
  method Action squash;
  method Action invalidate;
  method Action cacop(Bit#(5) op, Addr va, Data ctag);
  interface AxiMemMaster axiMem;
endinterface

// ============================================================
// Replacement policy interface
// ============================================================
interface ICacheReplace;
  method ICacheWayIdx replace(ICacheIndex setIdx);
  method Action       access(ICacheIndex setIdx, ICacheWayIdx wayIdx);
endinterface

// -------- LRU replacement --------
module mkICacheReplaceLRU(ICacheReplace);
  Vector#(ICacheSets, Vector#(ICacheWays, Reg#(ICacheWayIdx)))
    ages <- replicateM(replicateM(mkRegU));

  method ICacheWayIdx replace(ICacheIndex setIdx);
    ICacheWayIdx victim = 0;
    ICacheWayIdx maxAge = ages[setIdx][0];
    for (Integer i = 1; i < valueOf(ICacheWays); i = i + 1) begin
      if (ages[setIdx][i] > maxAge) begin
        victim = fromInteger(i);
        maxAge = ages[setIdx][i];
      end
    end
    return victim;
  endmethod

  method Action access(ICacheIndex setIdx, ICacheWayIdx wayIdx);
    for (Integer i = 0; i < valueOf(ICacheWays); i = i + 1) begin
      if (fromInteger(i) == wayIdx)
        ages[setIdx][i] <= 0;
      else if (ages[setIdx][i] < fromInteger(valueOf(ICacheWays) - 1))
        ages[setIdx][i] <= ages[setIdx][i] + 1;
    end
  endmethod
endmodule

// -------- Pseudo-LRU (tree-based) replacement --------
// Requires ICacheWays to be a power of two and >= 2
module mkICacheReplacePLRU(ICacheReplace);
  Vector#(ICacheSets, Reg#(Bit#(TSub#(ICacheWays, 1))))
    treeBits <- replicateM(mkRegU);

  method ICacheWayIdx replace(ICacheIndex setIdx);
    Bit#(TSub#(ICacheWays, 1)) t = treeBits[setIdx];
    ICacheWayIdx victim = 0;
    ICacheWayIdx node   = 0;
    for (Integer lv = 0; lv < valueOf(TLog#(ICacheWays)); lv = lv + 1) begin
      if (t[node] == 0) begin
        victim = victim << 1;
        node   = (node << 1) | 1;
      end else begin
        victim = (victim << 1) | 1;
        node   = (node << 1) + 2;
      end
    end
    return victim;
  endmethod

  method Action access(ICacheIndex setIdx, ICacheWayIdx wayIdx);
    Bit#(TSub#(ICacheWays, 1)) t = treeBits[setIdx];
    ICacheWayIdx node = 0;
    for (Integer lv = 0; lv < valueOf(TLog#(ICacheWays)); lv = lv + 1) begin
      Integer bitPos = valueOf(TLog#(ICacheWays)) - 1 - lv;
      Bit#(TSub#(ICacheWays, 1)) mask = 1 << node;
      if (wayIdx[bitPos] == 0) begin
        t    = t | mask;
        node = (node << 1) | 1;
      end else begin
        t    = t & ~mask;
        node = (node << 1) + 2;
      end
    end
    treeBits[setIdx] <= t;
  endmethod
endmodule

// -------- Random (round-robin) replacement --------
module mkICacheReplaceRandom(ICacheReplace);
  Reg#(ICacheWayIdx) cnt <- mkReg(0);

  method ICacheWayIdx replace(ICacheIndex setIdx);
    return cnt;
  endmethod

  method Action access(ICacheIndex setIdx, ICacheWayIdx wayIdx);
    cnt <= cnt + 1;
  endmethod
endmodule

// ============================================================
// ICache implementation
// ============================================================
typedef enum { Ready, StartRefill, WaitResp } ICacheState deriving (Bits, Eq);

(* synthesize *)
module mkICache(ICache);
  Vector#(ICacheSets, Vector#(ICacheWays, Reg#(ICacheTag)))   tagStore   <- replicateM(replicateM(mkRegU));
  Vector#(ICacheSets, Vector#(ICacheWays, Reg#(ICacheLine)))  dataStore  <- replicateM(replicateM(mkRegU));
  Vector#(ICacheSets, Vector#(ICacheWays, Reg#(Bool)))        validStore <- replicateM(replicateM(mkReg(False)));

  Reg#(ICacheState)     state          <- mkReg(Ready);
  Reg#(ICacheRefillReq) missReq        <- mkRegU;
  Reg#(Bit#(8))         beatIdx        <- mkRegU;
  Reg#(ICacheLine)      refillLine     <- mkRegU;
  Reg#(Bool)            refillMayWrite <- mkReg(False);
  Reg#(Bool)            epoch          <- mkReg(False);
  Reg#(Bool)            squashPending  <- mkReg(False);

  Fifo#(2, ICacheRefillReq)  refillReqQ  <- mkCFFifo;
  Fifo#(2, ICacheRefillResp) refillRespQ <- mkCFFifo;
  Fifo#(2, ICacheMaintReq)   maintQ      <- mkCFFifo;

  Fifo#(2, AxiReadAddr) arQ <- mkCFFifo;
  Fifo#(4, AxiReadData) rQ  <- mkCFFifo;

`ifdef ICACHE_REPLACE_RANDOM
  ICacheReplace replacer <- mkICacheReplaceRandom;
`else
`ifdef ICACHE_REPLACE_PLRU
  ICacheReplace replacer <- mkICacheReplacePLRU;
`else
  ICacheReplace replacer <- mkICacheReplaceLRU;
`endif
`endif

  rule doAcceptRefillReq (state == Ready && refillReqQ.notEmpty && !maintQ.notEmpty);
    let req = refillReqQ.first;
    refillReqQ.deq;
    missReq <= req;
    beatIdx <= 0;
    refillLine <= replicate(0);
    refillMayWrite <= True;
    state <= StartRefill;
  endrule

  rule doStartRefill (state == StartRefill);
    arQ.enq(AxiReadAddr{
      addr: missReq.useCache ? getIBlockBase(missReq.addr) : missReq.addr,
      len: missReq.useCache ? fromInteger(valueOf(ICacheLineWords) - 1) : 'b0,
      size: 3'd2,
      burst: missReq.useCache ? AxiBurstIncr : AxiBurstFixed
    });
    state <= WaitResp;
  endrule

  rule doRefill (state == WaitResp && rQ.notEmpty);
    let beat = rQ.first;
    rQ.deq;

    let idx  = getIIndex(missReq.addr);
    let tag  = getITag(missReq.addr);
    let wsel = getIWordSel(missReq.addr);
    let way  = replacer.replace(idx);

    Bit#(ICacheWordSelSz) lineIdx = truncate(beatIdx);
    ICacheLine nextLine = update(refillLine, lineIdx, beat.data);
    Bit#(8) nextBeat = beatIdx + 1;

    refillLine <= nextLine;
    beatIdx <= nextBeat;

    if (beat.last || nextBeat == fromInteger(valueOf(ICacheLineWords))) begin
      Bool liveMiss = missReq.useCache && refillMayWrite && (missReq.epoch == epoch);
      if (liveMiss) begin
        tagStore[idx][way]   <= tag;
        dataStore[idx][way]  <= nextLine;
        validStore[idx][way] <= True;
        replacer.access(idx, way);
      end
      if (!squashPending) begin
        refillRespQ.enq(ICacheRefillResp{
          addr: missReq.addr,
          inst: missReq.useCache ? nextLine[wsel] : beat.data,
          epoch: missReq.epoch
        });
      end
      refillMayWrite <= False;
      squashPending <= False;
      state <= Ready;
    end
  endrule

  rule doMaint (state == Ready && maintQ.notEmpty);
    let req = maintQ.first;
    maintQ.deq;

    case (req.kind)
      ICacheMaintInvalidate: begin
        for (Integer s = 0; s < valueOf(ICacheSets); s = s + 1) begin
          for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
            validStore[s][w] <= False;
          end
        end
      end

      ICacheMaintCacop: begin
        ICacheOpType opType = req.op[4:3];
        let idx = getIIndex(req.va);
        let way = getICacopWaySel(req.va);

        if (opType == 2'b00) begin
          validStore[idx][way] <= False;
        end
        else if (opType == 2'b01) begin
          validStore[idx][way] <= False;
        end
        else if (opType == 2'b10) begin
          Bool hit = False;
          ICacheWayIdx hitWay = 0;
          for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
            if (validStore[idx][w] && tagStore[idx][w] == getITag(req.va)) begin
              hit = True;
              hitWay = fromInteger(w);
            end
          end
          if (hit) begin
            validStore[idx][hitWay] <= False;
          end
        end
      end
    endcase
  endrule

  method ICacheProbeResp probe(Addr va);
    let idx = getIIndex(va);
    let wsel = getIWordSel(va);
    ICacheProbeResp setWays = noICacheProbe;
    for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
      setWays = update(setWays, fromInteger(w), ICacheProbeWay{
        valid: validStore[idx][w],
        tag: tagStore[idx][w],
        inst: dataStore[idx][w][wsel]
      });
    end
    return setWays;
  endmethod

  method Action refillReq(Addr pa, Bool useCache) if (refillReqQ.notFull);
    refillReqQ.enq(ICacheRefillReq{
      addr: pa,
      epoch: epoch,
      useCache: useCache
    });
  endmethod

  method ActionValue#(ICacheRefillResp) refillResp if (refillRespQ.notEmpty);
    let d = refillRespQ.first;
    refillRespQ.deq;
    return d;
  endmethod

  method Action commitHit(Addr va, ICacheWayIdx way);
    replacer.access(getIIndex(va), way);
  endmethod

  method Action flush;
    refillReqQ.clear();
    maintQ.clear();
    refillMayWrite <= False;
    if (state != Ready) begin
      squashPending <= True;
    end
    for (Integer s = 0; s < valueOf(ICacheSets); s = s + 1) begin
      for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
        validStore[s][w] <= False;
      end
    end
    epoch <= !epoch;
  endmethod

  method Action squash;
    refillReqQ.clear();
    maintQ.clear();
    refillMayWrite <= False;
    if (state != Ready) begin
      squashPending <= True;
    end
    epoch <= !epoch;
  endmethod

  method Action invalidate if (maintQ.notFull);
    maintQ.enq(ICacheMaintReq{
      kind: ICacheMaintInvalidate,
      op: 0,
      va: 0,
      ctag: 0
    });
  endmethod

  method Action cacop(Bit#(5) op, Addr va, Data ctag) if (maintQ.notFull);
    if (op[2:0] == 3'b000) begin
      maintQ.enq(ICacheMaintReq{
        kind: ICacheMaintCacop,
        op: op,
        va: va,
        ctag: ctag
      });
    end
  endmethod

  interface AxiMemMaster axiMem;
    method Bool rdAddrValid = arQ.notEmpty;

    method ActionValue#(AxiReadAddr) rdAddr;
      let x = arQ.first;
      arQ.deq;
      return x;
    endmethod

    method Action rdData(AxiReadData d);
      rQ.enq(d);
    endmethod

    method Bool wrAddrValid = False;

    method ActionValue#(AxiWriteAddr) wrAddr if (False);
      return ?;
    endmethod

    method Bool wrDataValid = False;

    method ActionValue#(AxiWriteData) wrData if (False);
      return ?;
    endmethod

    method Action wrResp(AxiWriteResp r);
      noAction;
    endmethod
  endinterface
endmodule
