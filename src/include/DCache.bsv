import Types::*;
import ProcTypes::*;
import MemTypes::*;
import Fifo::*;
import Vector::*;
import Autoconf::*;

typedef `CONFIG_DCACHE_SETS       DCacheSets; // number of sets
typedef `CONFIG_DCACHE_WAYS       DCacheWays; // set associativity
typedef `CONFIG_DCACHE_LINE_WORDS DCacheLineWords; // words per cache line

typedef TLog#(DCacheLineWords)                              DCacheWordSelSz;
typedef TAdd#(DCacheWordSelSz, 2)                           DCacheOffsetSz;
typedef TLog#(DCacheSets)                                   DCacheIndexSz;
typedef TSub#(AddrSz, TAdd#(DCacheIndexSz, DCacheOffsetSz)) DCacheTagSz;

typedef Bit#(DCacheWordSelSz)   DCacheWordSel;
typedef Bit#(DCacheIndexSz)     DCacheIndex;
typedef Bit#(DCacheTagSz)       DCacheTag;
typedef Bit#(TLog#(DCacheWays)) DCacheWayIdx;

typedef Vector#(DCacheLineWords, Data) DCacheLine;

function DCacheTag     getDTag(Addr a) = truncateLSB(a);
function DCacheIndex   getDIndex(Addr a) = truncate(a >> valueOf(DCacheOffsetSz));
function DCacheWordSel getDWordSel(Addr a) = truncate(a >> 2);
interface DCache;
  method Action req(MemReq r);
  method ActionValue#(Data) resp;
endinterface

interface DCacheReplace;
  method DCacheWayIdx replace(DCacheIndex setIdx);
  method Action       access(DCacheIndex setIdx, DCacheWayIdx wayIdx);
endinterface

module mkDCacheReplaceLRU(DCacheReplace);
  Vector#(DCacheSets, Vector#(DCacheWays, Reg#(DCacheWayIdx)))
  ages <- replicateM(replicateM(mkReg(0)));

  method DCacheWayIdx replace(DCacheIndex setIdx);
    DCacheWayIdx victim = 0;
    DCacheWayIdx maxAge = ages[setIdx][0];
    for (Integer i = 1; i < valueOf(DCacheWays); i = i + 1) begin
      if (ages[setIdx][i] > maxAge) begin
        victim = fromInteger(i);
        maxAge = ages[setIdx][i];
      end
    end
    return victim;
  endmethod

  method Action access(DCacheIndex setIdx, DCacheWayIdx wayIdx);
    for (Integer i = 0; i < valueOf(DCacheWays); i = i + 1) begin
      if (fromInteger(i) == wayIdx)
      ages[setIdx][i] <= 0;
      else if (ages[setIdx][i] < fromInteger(valueOf(DCacheWays) - 1))
      ages[setIdx][i] <= ages[setIdx][i] + 1;
    end
  endmethod
endmodule

module mkDCacheReplacePLRU(DCacheReplace);
  Vector#(DCacheSets, Reg#(Bit#(TSub#(DCacheWays, 1))))
  treeBits <- replicateM(mkReg(0));

  method DCacheWayIdx replace(DCacheIndex setIdx);
    Bit#(TSub#(DCacheWays, 1)) t = treeBits[setIdx];
    DCacheWayIdx victim = 0;
    DCacheWayIdx node = 0;
    for (Integer lv = 0; lv < valueOf(TLog#(DCacheWays)); lv = lv + 1) begin
      if (t[node] == 0) begin
        victim = victim << 1;
        node = (node << 1) | 1;
      end else begin
        victim = (victim << 1) | 1;
        node = (node << 1) + 2;
      end
    end
    return victim;
  endmethod

  method Action access(DCacheIndex setIdx, DCacheWayIdx wayIdx);
    Bit#(TSub#(DCacheWays, 1)) t = treeBits[setIdx];
    DCacheWayIdx node = 0;
    for (Integer lv = 0; lv < valueOf(TLog#(DCacheWays)); lv = lv + 1) begin
      Integer bitPos = valueOf(TLog#(DCacheWays)) - 1 - lv;
      Bit#(TSub#(DCacheWays, 1)) mask = 1 << node;
      if (wayIdx[bitPos] == 0) begin
        t = t | mask;
        node = (node << 1) | 1;
      end else begin
        t = t & ~mask;
        node = (node << 1) + 2;
      end
    end
    treeBits[setIdx] <= t;
  endmethod
endmodule

module mkDCacheReplaceRandom(DCacheReplace);
  Reg#(DCacheWayIdx) cnt <- mkReg(0);

  method DCacheWayIdx replace(DCacheIndex setIdx);
    return cnt;
  endmethod

  method Action access(DCacheIndex setIdx, DCacheWayIdx wayIdx);
    cnt <= cnt + 1;
  endmethod
endmodule

typedef enum { Ready, StartMiss, WaitResp} DCacheState deriving(Bits, Eq);

module mkDCache(DCache);
  Vector#(DCacheSets, Vector#(DCacheWays, Reg#(DCacheTag)))   tagStore <- replicateM(replicateM(mkRegU));
  Vector#(DCacheSets, Vector#(DCacheWays, Reg#(DCacheLine)))  dataStore <- replicateM(replicateM(mkRegU));
  Vector#(DCacheSets, Vector#(DCacheWays, Reg#(Bool)))        validStore <- replicateM(replicateM(mkReg(False)));
  Vector#(DCacheSets, Vector#(DCacheWays, Reg#(Bool)))        dirtyStore <- replicateM(replicateM(mkReg(False)));

  Reg#(DCacheState) state <- mkReg(Ready);
  Reg#(MemReq)      missReq <- mkRegU;

  Reg#(Bool) lrValid <- mkReg(False);
  Reg#(Addr) lrAddr <- mkRegU;

  Fifo#(2, MemReq) reqQ <- mkCFFifo;
  Fifo#(2, Data)   respQ <- mkCFFifo;

  `ifdef DCACHE_REPLACE_RANDOM
  DCacheReplace replacer <- mkDCacheReplaceRandom;
  `else
  `ifdef DCACHE_REPLACE_PLRU
  DCacheReplace replacer <- mkDCacheReplacePLRU;
  `else
  DCacheReplace replacer <- mkDCacheReplaceLRU;
  `endif
  `endif

  rule doLookup (state == Ready);
    let r = reqQ.first;

    if (r.op == Fence) begin
      reqQ.deq;
    end else begin
      let tag = getDTag(r.addr);
      let idx = getDIndex(r.addr);
      let wsel = getDWordSel(r.addr);

      Bool         hit = False;
      Data         hitData = 0;
      DCacheLine   hitLine = replicate(0);
      DCacheWayIdx hitWay = 0;

      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        if (validStore[idx][w] && tagStore[idx][w] == tag) begin
          hit = True;
          hitData = dataStore[idx][w][wsel];
          hitLine = dataStore[idx][w];
          hitWay = fromInteger(w);
        end
      end

      if (hit) begin
        reqQ.deq;
        replacer.access(idx, hitWay);

        case (r.op)
          Ld: respQ.enq(hitData);
          Lr: begin
            respQ.enq(hitData);
            lrValid <= True;
            lrAddr <= r.addr;
          end
          Sc: begin
            if (lrValid && lrAddr == r.addr)
            respQ.enq(scSucc);
            else
            respQ.enq(scFail);
            lrValid <= False;
          end
          default: begin end
        endcase

        Bool doWrite = (r.op == St) ||
        (r.op == Sc && lrValid && lrAddr == r.addr);
        if (doWrite) begin
          DCacheLine newLine = update(hitLine, wsel, r.data);
          for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
            if (fromInteger(w) == hitWay) begin
              dataStore[idx][w] <= newLine;
              dirtyStore[idx][w] <= True;
            end
          end
        end

        if (r.op == St && lrValid && lrAddr == r.addr)
        lrValid <= False;
      end else begin
        if (r.op == Sc) begin
          reqQ.deq;
          respQ.enq(scFail);
          lrValid <= False;
        end else begin
          missReq <= r;
          state <= StartMiss;
        end
      end
    end
  endrule

  rule doStartMiss (state == StartMiss);
    state <= WaitResp;
  endrule

  rule doWaitResp (state == WaitResp);
  endrule

  method Action req(MemReq r);
    reqQ.enq(r);
  endmethod

  method ActionValue#(Data) resp;
    let d = respQ.first;
    respQ.deq;
    return d;
  endmethod
endmodule
