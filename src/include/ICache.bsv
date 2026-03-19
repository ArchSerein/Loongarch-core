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
typedef TSub#(AddrSz, TAdd#(ICacheIndexSz, ICacheOffsetSz)) ICacheTagSz;

typedef Bit#(ICacheWordSelSz)   ICacheWordSel;
typedef Bit#(ICacheIndexSz)     ICacheIndex;
typedef Bit#(ICacheTagSz)       ICacheTag;
typedef Bit#(TLog#(ICacheWays)) ICacheWayIdx;

typedef Vector#(ICacheLineWords, Data) ICacheLine;

// ============================================================
// Address decomposition
// ============================================================
function ICacheTag     getITag(Addr a)     = truncateLSB(a);
function ICacheIndex   getIIndex(Addr a)   = truncate(a >> valueOf(ICacheOffsetSz));
function ICacheWordSel getIWordSel(Addr a) = truncate(a >> 2);
function Addr          getIBlockBase(Addr a) = { truncateLSB(a >> valueOf(ICacheOffsetSz))
                                               , 0 };

interface ICache;
  method Action req(Addr a);
  method ActionValue#(Instruction) resp;
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

module mkICache(ICache);
  Vector#(ICacheSets, Vector#(ICacheWays, Reg#(ICacheTag)))   tagStore   <- replicateM(replicateM(mkRegU));
  Vector#(ICacheSets, Vector#(ICacheWays, Reg#(ICacheLine)))  dataStore  <- replicateM(replicateM(mkRegU));
  Vector#(ICacheSets, Vector#(ICacheWays, Reg#(Bool)))        validStore <- replicateM(replicateM(mkReg(False)));

  Reg#(ICacheState) state    <- mkReg(Ready);
  Reg#(Addr)        missAddr <- mkRegU;
  Reg#(Bit#(8))     beatIdx  <- mkReg(0);
  Reg#(ICacheLine)  refillLine <- mkReg(replicate(0));

  Fifo#(2, Addr)        reqQ  <- mkCFFifo;
  Fifo#(2, Instruction) respQ <- mkCFFifo;

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

  rule doStartMiss (state == StartMiss);
    arQ.enq(AxiReadAddr{
      addr: getIBlockBase(missAddr),
      len: fromInteger(valueOf(ICacheLineWords) - 1),
      size: 3'd2,
      burst: AxiBurstIncr
    });
    beatIdx <= 0;
    refillLine <= replicate(0);
    state <= WaitResp;
  endrule

  rule doRefill (state == WaitResp && rQ.notEmpty);
    let beat = rQ.first;
    rQ.deq;

    let idx  = getIIndex(missAddr);
    let tag  = getITag(missAddr);
    let wsel = getIWordSel(missAddr);
    let way  = replacer.replace(idx);

    Bit#(ICacheWordSelSz) lineIdx = truncate(beatIdx);
    ICacheLine nextLine = update(refillLine, lineIdx, beat.data);
    Bit#(8) nextBeat = beatIdx + 1;

    refillLine <= nextLine;
    beatIdx <= nextBeat;

    if (beat.last || nextBeat == fromInteger(valueOf(ICacheLineWords))) begin
      tagStore[idx][way]   <= tag;
      dataStore[idx][way]  <= nextLine;
      validStore[idx][way] <= True;
      replacer.access(idx, way);
      respQ.enq(nextLine[wsel]);
      reqQ.deq;
      state <= Ready;
    end
  endrule

  method Action req(Addr a);
    reqQ.enq(a);
  endmethod

  method ActionValue#(Instruction) resp;
    let d = respQ.first;
    respQ.deq;
    return d;
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
