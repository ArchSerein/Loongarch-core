import Types::*;
import ProcTypes::*;
import CacheTypes::*;
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
typedef TSub#(AddrSz, TAdd#(ICacheIndexSz, ICacheOffsetSz)) ICacheTagSz;

typedef Bit#(ICacheWordSelSz)   ICacheWordSel;
typedef Bit#(ICacheIndexSz)     ICacheIndex;
typedef Bit#(ICacheTagSz)       ICacheTag;
typedef Bit#(TLog#(ICacheWays)) ICacheWayIdx;

typedef Vector#(ICacheLineWords, Data) ICacheLine;

function ICacheLine wideRespToILine(WideMemResp line);
  ICacheLine ret = ?;
  for (Integer i = 0; i < valueOf(ICacheLineWords); i = i + 1) begin
    ret[i] = line[i];
  end
  return ret;
endfunction

// ============================================================
// Address decomposition
// ============================================================
function ICacheTag     getITag(Addr a)     = truncateLSB(a);
function ICacheIndex   getIIndex(Addr a)   = truncate(a >> valueOf(ICacheOffsetSz));
function ICacheWordSel getIWordSel(Addr a) = truncate(a >> 2);

// ICache interface is defined in CacheTypes.bsv

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
    ages <- replicateM(replicateM(mkReg(0)));

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
  // (ways - 1) tree bits per set, packed into a single register
  Vector#(ICacheSets, Reg#(Bit#(TSub#(ICacheWays, 1))))
    treeBits <- replicateM(mkReg(0));

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
typedef enum { Ready, StartMiss, WaitResp } ICacheState deriving (Bits, Eq);

module mkICache#(WideMem mem)(ICache);
  // Tag / data / valid storage
  Vector#(ICacheSets, Vector#(ICacheWays, Reg#(ICacheTag)))   tagStore   <- replicateM(replicateM(mkRegU));
  Vector#(ICacheSets, Vector#(ICacheWays, Reg#(ICacheLine)))  dataStore  <- replicateM(replicateM(mkRegU));
  Vector#(ICacheSets, Vector#(ICacheWays, Reg#(Bool)))        validStore <- replicateM(replicateM(mkReg(False)));

  // FSM state
  Reg#(ICacheState) state    <- mkReg(Ready);
  Reg#(Addr)        missAddr <- mkRegU;

  // Request / response FIFOs (from include/Fifo.bsv)
  Fifo#(2, Addr)        reqQ  <- mkCFFifo;
  Fifo#(2, Instruction) respQ <- mkCFFifo;

  // Replacement policy (selected by Kconfig macro)
`ifdef ICACHE_REPLACE_RANDOM
  ICacheReplace replacer <- mkICacheReplaceRandom;
`else
`ifdef ICACHE_REPLACE_PLRU
  ICacheReplace replacer <- mkICacheReplacePLRU;
`else
  ICacheReplace replacer <- mkICacheReplaceLRU;
`endif
`endif

  // ---- Tag lookup ----
  rule doLookup (state == Ready);
    let addr = reqQ.first;
    let tag  = getITag(addr);
    let idx  = getIIndex(addr);
    let wsel = getIWordSel(addr);

    Bool         hit     = False;
    Data         hitData = 0;
    ICacheWayIdx hitWay  = 0;

    for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
      if (validStore[idx][w] && tagStore[idx][w] == tag) begin
        hit     = True;
        hitData = dataStore[idx][w][wsel];
        hitWay  = fromInteger(w);
      end
    end

    if (hit) begin
      reqQ.deq;
      respQ.enq(hitData);
      replacer.access(idx, hitWay);
    end else begin
      missAddr <= addr;
      state    <= StartMiss;
    end
  endrule

  // ---- Send miss request to memory ----
  rule doStartMiss (state == StartMiss);
    mem.req(WideMemReq{
      write_en: 0,
      addr: missAddr,
      data: replicate(0),
      burst_len: fromInteger(valueOf(ICacheLineWords))
    });
    state <= WaitResp;
  endrule

  // ---- Receive line from memory and fill ----
  rule doWaitResp (state == WaitResp);
    let wideLine <- mem.resp;
    let line = wideRespToILine(wideLine);
    let idx  = getIIndex(missAddr);
    let tag  = getITag(missAddr);
    let wsel = getIWordSel(missAddr);
    let way  = replacer.replace(idx);

    tagStore[idx][way]   <= tag;
    dataStore[idx][way]  <= line;
    validStore[idx][way] <= True;
    replacer.access(idx, way);
    respQ.enq(line[wsel]);
    reqQ.deq;
    state <= Ready;
  endrule

  method Action req(Addr a);
    reqQ.enq(a);
  endmethod

  method ActionValue#(Instruction) resp;
    let d = respQ.first;
    respQ.deq;
    return d;
  endmethod
endmodule
