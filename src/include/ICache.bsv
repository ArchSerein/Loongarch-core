import Types::*;
import ProcTypes::*;
import AxiTypes::*;
import Fifo::*;
import Vector::*;
import RegFile::*;
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
  Bool      valid;
  ICacheTag tag;
} ICacheTagValid deriving (Bits, Eq);
typedef TAdd#(1, ICacheTagSz) ICacheTagValidSz;
typedef struct {
  Bool        valid;
  ICacheTag   tag;
  Instruction inst;
} ICacheProbeWay deriving (Bits, Eq);
typedef Vector#(ICacheWays, ICacheProbeWay) ICacheProbeResp;

function ICacheProbeResp noICacheProbe;
  return replicate(ICacheProbeWay{valid: False, tag: 0, inst: 0});
endfunction

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
function Bit#(ICacheTagValidSz) packICacheTagValid(ICacheTagValid tv);
  return { pack(tv.valid), tv.tag };
endfunction
function ICacheTagValid unpackICacheTagValid(Bit#(ICacheTagValidSz) bits);
  return ICacheTagValid{valid: unpack(msb(bits)), tag: truncate(bits)};
endfunction

interface ICache;
  method Action probe(Addr va);
  method ICacheProbeResp probeResp;
  method Action refillReq(Addr pa, Bool useCache);
  method ActionValue#(ICacheRefillResp) refillResp;
  method Action commitHit(Addr va, ICacheWayIdx way);
  method Action flush;
  method Action squash;
  method Action invalidate;
  method Action cacop(Bit#(5) op, Addr va, Data ctag);
  method ActionValue#(Bool) cacopResp;
  interface AxiMemMaster axiMem;
endinterface

interface ICacheTagSram;
  method Action put(Bit#(1) wea, ICacheIndex addra, Bit#(ICacheTagValidSz) dina);
  method Bit#(ICacheTagValidSz) read;
endinterface

interface ICacheDataSram;
  method Action put(Bit#(1) wea, ICacheIndex addra, Data dina);
  method Data read;
endinterface

`ifndef CONFIG_FPGA
module mkICacheTagSram(ICacheTagSram);
  RegFile#(ICacheIndex, Bit#(ICacheTagValidSz)) mem <- mkRegFileFull;
  Reg#(Bit#(ICacheTagValidSz)) dout <- mkReg(0);

  method Action put(Bit#(1) wea, ICacheIndex addra, Bit#(ICacheTagValidSz) dina);
    if (wea[0] == 1'b1) begin
      mem.upd(addra, dina);
      dout <= dina;
    end else begin
      dout <= mem.sub(addra);
    end
  endmethod

  method Bit#(ICacheTagValidSz) read = dout;
endmodule

module mkICacheDataSram(ICacheDataSram);
  RegFile#(ICacheIndex, Data) mem <- mkRegFileFull;
  Reg#(Data) dout <- mkReg(0);

  method Action put(Bit#(1) wea, ICacheIndex addra, Data dina);
    if (wea[0] == 1'b1) begin
      mem.upd(addra, dina);
      dout <= dina;
    end else begin
      dout <= mem.sub(addra);
    end
  endmethod

  method Data read = dout;
endmodule
`else
import "BVI" sram_128x22 =
module mkICacheTagSram(ICacheTagSram);
  default_clock clk(clka);
  default_reset no_reset;

  method put(wea, addra, dina) enable(ena);
  method douta read();

  schedule (read) CF (read);
  schedule (put) CF (read);
  schedule (put) C (put);
endmodule

import "BVI" sram_128x32 =
module mkICacheDataSram(ICacheDataSram);
  default_clock clk(clka);
  default_reset no_reset;

  method put(wea, addra, dina) enable(ena);
  method douta read();

  schedule (read) CF (read);
  schedule (put) CF (read);
  schedule (put) C (put);
endmodule
`endif

// ============================================================
// Replacement policy interface
// ============================================================
interface ICacheReplace;
  method ICacheWayIdx replace(ICacheIndex setIdx);
  method Action       access(ICacheIndex setIdx, ICacheWayIdx wayIdx);
endinterface

// -------- LRU replacement --------
module mkICacheReplaceLRU(ICacheReplace);
  RegFile#(ICacheIndex, Vector#(ICacheWays, ICacheWayIdx)) ages <- mkRegFileFull;

  method ICacheWayIdx replace(ICacheIndex setIdx);
    Vector#(ICacheWays, ICacheWayIdx) ageVec = ages.sub(setIdx);
    ICacheWayIdx victim = 0;
    ICacheWayIdx maxAge = ageVec[0];
    for (Integer i = 1; i < valueOf(ICacheWays); i = i + 1) begin
      if (ageVec[i] > maxAge) begin
        victim = fromInteger(i);
        maxAge = ageVec[i];
      end
    end
    return victim;
  endmethod

  method Action access(ICacheIndex setIdx, ICacheWayIdx wayIdx);
    Vector#(ICacheWays, ICacheWayIdx) ageVec = ages.sub(setIdx);
    Vector#(ICacheWays, ICacheWayIdx) nextAgeVec = ageVec;
    for (Integer i = 0; i < valueOf(ICacheWays); i = i + 1) begin
      if (fromInteger(i) == wayIdx)
        nextAgeVec = update(nextAgeVec, fromInteger(i), 0);
      else if (ageVec[i] < fromInteger(valueOf(ICacheWays) - 1))
        nextAgeVec = update(nextAgeVec, fromInteger(i), ageVec[i] + 1);
    end
    ages.upd(setIdx, nextAgeVec);
  endmethod
endmodule

// -------- Pseudo-LRU (tree-based) replacement --------
// Requires ICacheWays to be a power of two and >= 2
module mkICacheReplacePLRU(ICacheReplace);
  RegFile#(ICacheIndex, Bit#(TSub#(ICacheWays, 1))) treeBits <- mkRegFileFull;

  method ICacheWayIdx replace(ICacheIndex setIdx);
    Bit#(TSub#(ICacheWays, 1)) t = treeBits.sub(setIdx);
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
    Bit#(TSub#(ICacheWays, 1)) t = treeBits.sub(setIdx);
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
    treeBits.upd(setIdx, t);
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
typedef enum {
  Ready,
  StartRefill,
  WaitResp,
  CacopLookup,
  FlushAll
} ICacheState deriving (Bits, Eq);

(* synthesize *)
module mkICache(ICache);
  Vector#(ICacheWays, ICacheTagSram) tagValidStore <- replicateM(mkICacheTagSram);
  Vector#(ICacheWays, Vector#(ICacheLineWords, ICacheDataSram))
    dataStore <- replicateM(replicateM(mkICacheDataSram));

  Reg#(ICacheState)     state          <- mkReg(FlushAll);
  Reg#(ICacheRefillReq) missReq        <- mkRegU;
  Reg#(Bit#(8))         beatIdx        <- mkRegU;
  Reg#(ICacheLine)      refillLine     <- mkRegU;
  Reg#(Bool)            refillMayWrite <- mkReg(False);
  Reg#(Bool)            epoch          <- mkReg(False);
  Reg#(Bool)            squashPending  <- mkReg(False);
  Reg#(ICacheWordSel)   probeWordSel   <- mkReg(0);
  Reg#(Addr)            cacopVaReg     <- mkRegU;
  Reg#(Data)            cacopTagReg    <- mkRegU;
  Reg#(ICacheIndex)     flushIdx       <- mkReg(0);
  Reg#(ICacheWayIdx)    flushWay       <- mkReg(0);

  Fifo#(2, ICacheRefillReq)  refillReqQ  <- mkCFFifo;
  Fifo#(2, ICacheRefillResp) refillRespQ <- mkCFFifo;
  Fifo#(2, Bool)             cacopRespQ  <- mkCFFifo;

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

  function Action issueRead(ICacheIndex idx, ICacheWordSel wsel);
    action
      for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
        tagValidStore[w].put(1'b0, idx, 0);
        for (Integer b = 0; b < valueOf(ICacheLineWords); b = b + 1) begin
          if (fromInteger(b) == wsel) begin
            dataStore[w][b].put(1'b0, idx, 0);
          end
        end
      end
      probeWordSel <= wsel;
    endaction
  endfunction

  function Action writeTagValid(ICacheWayIdx way, ICacheIndex idx, ICacheTagValid tv);
    action
      for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
        if (fromInteger(w) == way) begin
          tagValidStore[w].put(1'b1, idx, packICacheTagValid(tv));
        end
      end
    endaction
  endfunction

  function Action writeLine(ICacheWayIdx way, ICacheIndex idx, ICacheLine line);
    action
      for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
        if (fromInteger(w) == way) begin
          for (Integer b = 0; b < valueOf(ICacheLineWords); b = b + 1) begin
            dataStore[w][b].put(1'b1, idx, line[b]);
          end
        end
      end
    endaction
  endfunction

  function ICacheProbeResp currentProbeResp;
    ICacheProbeResp setWays = noICacheProbe;
    for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
      ICacheTagValid tv = unpackICacheTagValid(tagValidStore[w].read);
      setWays = update(setWays, fromInteger(w), ICacheProbeWay{
        valid: tv.valid,
        tag: tv.tag,
        inst: dataStore[w][probeWordSel].read
      });
    end
    return setWays;
  endfunction

  rule doAcceptRefillReq (state == Ready && refillReqQ.notEmpty);
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
        writeTagValid(way, idx, ICacheTagValid{valid: True, tag: tag});
        writeLine(way, idx, nextLine);
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

  rule doCacopLookup (state == CacopLookup);
    let idx = getIIndex(cacopVaReg);
    Bool hit = False;
    ICacheWayIdx hitWay = 0;
    for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
      ICacheTagValid tv = unpackICacheTagValid(tagValidStore[w].read);
      if (tv.valid && tv.tag == getITag(cacopTagReg)) begin
        hit = True;
        hitWay = fromInteger(w);
      end
    end
    if (hit) begin
      writeTagValid(hitWay, idx, ICacheTagValid{valid: False, tag: 0});
    end
    cacopRespQ.enq(True);
    state <= Ready;
  endrule

  rule doFlushAll (state == FlushAll);
    writeTagValid(flushWay, flushIdx, ICacheTagValid{valid: False, tag: 0});
    Bool lastWay = flushWay == fromInteger(valueOf(ICacheWays) - 1);
    Bool lastIdx = flushIdx == fromInteger(valueOf(ICacheSets) - 1);
    if (lastWay && lastIdx) begin
      state <= Ready;
    end else if (lastWay) begin
      flushWay <= 0;
      flushIdx <= flushIdx + 1;
    end else begin
      flushWay <= flushWay + 1;
    end
  endrule

  method Action probe(Addr va) if (state == Ready);
    issueRead(getIIndex(va), getIWordSel(va));
  endmethod

  method ICacheProbeResp probeResp;
    return currentProbeResp;
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
    cacopRespQ.clear();
    refillMayWrite <= False;
    if (state != Ready) begin
      squashPending <= True;
    end
    flushIdx <= 0;
    flushWay <= 0;
    state <= FlushAll;
    epoch <= !epoch;
  endmethod

  method Action squash;
    refillReqQ.clear();
    cacopRespQ.clear();
    refillMayWrite <= False;
    if (state != Ready) begin
      squashPending <= True;
    end
    epoch <= !epoch;
  endmethod

  method Action invalidate if (state == Ready && !refillReqQ.notEmpty);
    flushIdx <= 0;
    flushWay <= 0;
    state <= FlushAll;
  endmethod

  method Action cacop(Bit#(5) op, Addr va, Data ctag)
      if (state == Ready && !refillReqQ.notEmpty && cacopRespQ.notFull);
    if (op[2:0] == 3'b000) begin
      ICacheOpType opType = op[4:3];
      let idx = getIIndex(va);
      let way = getICacopWaySel(va);

      if (opType == 2'b00) begin
        writeTagValid(way, idx, ICacheTagValid{valid: False, tag: 0});
        cacopRespQ.enq(True);
      end
      else if (opType == 2'b01) begin
        writeTagValid(way, idx, ICacheTagValid{valid: False, tag: 0});
        cacopRespQ.enq(True);
      end
      else if (opType == 2'b10) begin
        issueRead(idx, getIWordSel(va));
        cacopVaReg <= va;
        cacopTagReg <= ctag;
        state <= CacopLookup;
      end else begin
        cacopRespQ.enq(True);
      end
    end else begin
      cacopRespQ.enq(True);
    end
  endmethod

  method ActionValue#(Bool) cacopResp if (cacopRespQ.notEmpty);
    let d = cacopRespQ.first;
    cacopRespQ.deq;
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
