import Types::*;
import ProcTypes::*;
import MemTypes::*;
import AxiTypes::*;
import Fifo::*;
import Vector::*;
import Param::*;
import Assert::*;
import RegFile::*;
`include "Autoconf.bsv"
`ifdef CONFIG_TRACE_PERFORMANCE
import Perf::*;
`endif

typedef `CONFIG_DCACHE_SETS       DCacheSets; // number of sets
typedef `CONFIG_DCACHE_WAYS       DCacheWays; // set associativity
typedef `CONFIG_DCACHE_LINE_WORDS DCacheLineWords; // words per cache line

typedef TLog#(DCacheLineWords)                              DCacheWordSelSz;
typedef TAdd#(DCacheWordSelSz, 2)                           DCacheOffsetSz;
typedef TLog#(DCacheSets)                                   DCacheIndexSz;
typedef TAdd#(DCacheOffsetSz, DCacheIndexSz)                DCacheWaySelOffSz;
typedef TSub#(AddrSz, TAdd#(DCacheIndexSz, DCacheOffsetSz)) DCacheTagSz;

typedef Bit#(DCacheWordSelSz)   DCacheWordSel;
typedef Bit#(DCacheIndexSz)     DCacheIndex;
typedef Bit#(DCacheTagSz)       DCacheTag;
typedef Bit#(TLog#(DCacheWays)) DCacheWayIdx;
typedef Bit#(2)                 DCacheOpType;

typedef Vector#(DCacheLineWords, Data) DCacheLine;
typedef Vector#(DCacheWays, Bool) DCacheDirtyLine;
typedef struct {
  Bool      valid;
  DCacheTag tag;
} DCacheTagValid deriving(Bits, Eq);
typedef TAdd#(1, DCacheTagSz) DCacheTagValidSz;

typedef struct {
  DCacheIndex   idx;
  DCacheWayIdx  way;
  DCacheWordSel wsel;
  Data          data;
} DCacheWriteBuffer deriving(Bits, Eq);

typedef struct {
  Data data;
} DCacheResp deriving(Bits, Eq);

function DCacheTag     getDTag(Addr a) = truncateLSB(a);
function DCacheIndex   getDIndex(Addr a) = truncate(a >> valueOf(DCacheOffsetSz));
function DCacheWordSel getDWordSel(Addr a) = truncate(a >> 2);
function DCacheWayIdx  getDCacopWaySel(Addr a) = truncate(a);
function Addr getDBlockBase(Addr a);
  Bit#(TSub#(AddrSz, DCacheOffsetSz)) upper = truncateLSB(a);
  Bit#(DCacheOffsetSz) lower = 0;
  return { upper, lower };
endfunction
function Bit#(DCacheTagValidSz) packDCacheTagValid(DCacheTagValid tv);
  return { pack(tv.valid), tv.tag };
endfunction
function DCacheTagValid unpackDCacheTagValid(Bit#(DCacheTagValidSz) bits);
  return DCacheTagValid{valid: unpack(msb(bits)), tag: truncate(bits)};
endfunction

function Data applyByteMask(Data oldData, Data newData, Bit#(WordSz) byteEn);
  Data merged = oldData;
  for (Integer i = 0; i < valueOf(WordSz); i = i + 1) begin
    if (byteEn[i] == 1'b1) begin
      Bit#(8) b = newData[(8 * i) + 7 : (8 * i)];
      merged[(8 * i) + 7 : (8 * i)] = b;
    end
  end
  return merged;
endfunction

interface DCache;
  method Action req(MemReq r);
  method Action cacop(MemReq r);
  method ActionValue#(DCacheResp) resp;
  method Action squash(Bool clearLl);
  interface AxiMemMaster axiMem;
endinterface

interface DCacheTagSram;
  method Action put(Bit#(1) wea, DCacheIndex addra, Bit#(DCacheTagValidSz) dina);
  method Bit#(DCacheTagValidSz) read;
endinterface

interface DCacheDataSram;
  method Action put(Bit#(1) wea, DCacheIndex addra, Data dina);
  method Data read;
endinterface

`ifndef CONFIG_FPGA
module mkDCacheTagSram(DCacheTagSram);
  RegFile#(DCacheIndex, Bit#(DCacheTagValidSz)) mem <- mkRegFileFull;
  Reg#(Bit#(DCacheTagValidSz)) dout <- mkReg(0);

  method Action put(Bit#(1) wea, DCacheIndex addra, Bit#(DCacheTagValidSz) dina);
    if (wea[0] == 1'b1) begin
      mem.upd(addra, dina);
      dout <= dina;
    end else begin
      dout <= mem.sub(addra);
    end
  endmethod

  method Bit#(DCacheTagValidSz) read = dout;
endmodule

module mkDCacheDataSram(DCacheDataSram);
  RegFile#(DCacheIndex, Data) mem <- mkRegFileFull;
  Reg#(Data) dout <- mkReg(0);

  method Action put(Bit#(1) wea, DCacheIndex addra, Data dina);
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
module mkDCacheTagSram(DCacheTagSram);
  default_clock clk(clka);
  default_reset no_reset;

  method put(wea, addra, dina) enable(ena);
  method douta read();

  schedule (read) CF (read);
  schedule (put) CF (read);
  schedule (put) C (put);
endmodule

import "BVI" sram_128x32 =
module mkDCacheDataSram(DCacheDataSram);
  default_clock clk(clka);
  default_reset no_reset;

  method put(wea, addra, dina) enable(ena);
  method douta read();

  schedule (read) CF (read);
  schedule (put) CF (read);
  schedule (put) C (put);
endmodule
`endif

interface DCacheReplace;
  method DCacheWayIdx replace(DCacheIndex setIdx);
  method Action       access(DCacheIndex setIdx, DCacheWayIdx wayIdx);
endinterface

module mkDCacheReplaceLRU(DCacheReplace);
  RegFile#(DCacheIndex, Vector#(DCacheWays, DCacheWayIdx)) ages <- mkRegFileFull;

  method DCacheWayIdx replace(DCacheIndex setIdx);
    Vector#(DCacheWays, DCacheWayIdx) ageVec = ages.sub(setIdx);
    DCacheWayIdx victim = 0;
    DCacheWayIdx maxAge = ageVec[0];
    for (Integer i = 1; i < valueOf(DCacheWays); i = i + 1) begin
      if (ageVec[i] > maxAge) begin
        victim = fromInteger(i);
        maxAge = ageVec[i];
      end
    end
    return victim;
  endmethod

  method Action access(DCacheIndex setIdx, DCacheWayIdx wayIdx);
    Vector#(DCacheWays, DCacheWayIdx) ageVec = ages.sub(setIdx);
    Vector#(DCacheWays, DCacheWayIdx) nextAgeVec = ageVec;
    for (Integer i = 0; i < valueOf(DCacheWays); i = i + 1) begin
      if (fromInteger(i) == wayIdx)
        nextAgeVec = update(nextAgeVec, fromInteger(i), 0);
      else if (ageVec[i] < fromInteger(valueOf(DCacheWays) - 1))
        nextAgeVec = update(nextAgeVec, fromInteger(i), ageVec[i] + 1);
    end
    ages.upd(setIdx, nextAgeVec);
  endmethod
endmodule

module mkDCacheReplacePLRU(DCacheReplace);
  RegFile#(DCacheIndex, Bit#(TSub#(DCacheWays, 1))) treeBits <- mkRegFileFull;

  method DCacheWayIdx replace(DCacheIndex setIdx);
    Bit#(TSub#(DCacheWays, 1)) t = treeBits.sub(setIdx);
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
    Bit#(TSub#(DCacheWays, 1)) t = treeBits.sub(setIdx);
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
    treeBits.upd(setIdx, t);
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

typedef enum {
  Init,
  Ready,
  LookupResp,
  SendWbData,
  WaitWbResp,
  SendFillAddr,
  WaitFillResp,
  SendUncacheReq,
  WaitUncacheResp
} DCacheState deriving(Bits, Eq);

(* synthesize *)
module mkDCache(DCache);
  Vector#(DCacheWays, DCacheTagSram) tagValidStore <- replicateM(mkDCacheTagSram);
  Vector#(DCacheWays, Vector#(DCacheLineWords, DCacheDataSram))
    dataStore <- replicateM(replicateM(mkDCacheDataSram));
  RegFile#(DCacheIndex, DCacheDirtyLine) dirtyStore <- mkRegFileFull;

  Reg#(DCacheState) state <- mkReg(Init);
  Reg#(DCacheIndex) initIdx <- mkReg(0);
  Reg#(DCacheWayIdx) initWay <- mkReg(0);
  Reg#(MemReq)      lookupReq <- mkRegU;
  Reg#(MemReq)      missReq <- mkRegU;
  Reg#(DCacheWayIdx) victimWay <- mkRegU;
  Reg#(DCacheLine)   wbLine <- mkRegU;
  Reg#(Bit#(8))      beatIdx <- mkRegU;
  Reg#(DCacheLine)   fillLine <- mkRegU;

  Reg#(Bool) llValid <- mkReg(False);
  Reg#(Addr) llAddr <- mkRegU;
  Reg#(Bool) squashPending <- mkReg(False);
  Reg#(Bool) fenceFlushWait <- mkReg(False);
  Reg#(Bool) cacheMaintWait <- mkReg(False);
  Reg#(DCacheIndex) cacheMaintIdx <- mkRegU;
  Reg#(DCacheWayIdx) cacheMaintWay <- mkRegU;
  Reg#(Addr) cacheMaintBlockAddr <- mkRegU;
  Reg#(Bool) writeBufferValid <- mkReg(False);
  Reg#(DCacheWriteBuffer) writeBuffer <- mkRegU;

  Fifo#(2, MemReq) reqQ <- mkCFFifo;
  Fifo#(2, DCacheResp) respQ <- mkCFFifo;

  Fifo#(2, AxiReadAddr)   arQ <- mkCFFifo;
  Fifo#(4, AxiReadData)   rQ  <- mkCFFifo;
  Fifo#(2, AxiWriteAddr)  awQ <- mkCFFifo;
  Fifo#(4, AxiWriteData)  wQ  <- mkCFFifo;
  Fifo#(2, AxiWriteResp)  bQ  <- mkCFFifo;

  `ifdef DCACHE_REPLACE_RANDOM
  DCacheReplace replacer <- mkDCacheReplaceRandom;
  `else
  `ifdef DCACHE_REPLACE_PLRU
  DCacheReplace replacer <- mkDCacheReplacePLRU;
  `else
  DCacheReplace replacer <- mkDCacheReplaceLRU;
  `endif
  `endif

  function Action issueRead(DCacheIndex idx);
    action
      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        tagValidStore[w].put(1'b0, idx, 0);
        for (Integer b = 0; b < valueOf(DCacheLineWords); b = b + 1) begin
          dataStore[w][b].put(1'b0, idx, 0);
        end
      end
    endaction
  endfunction

  function Action writeTagValid(DCacheWayIdx way, DCacheIndex idx, DCacheTagValid tv);
    action
      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        if (fromInteger(w) == way) begin
          tagValidStore[w].put(1'b1, idx, packDCacheTagValid(tv));
        end
      end
    endaction
  endfunction

  function DCacheDirtyLine currentDirties(DCacheIndex idx);
    return dirtyStore.sub(idx);
  endfunction

  function Action writeDirty(DCacheIndex idx, DCacheWayIdx way, Bool dirty);
    action
      DCacheDirtyLine dirtyLine = dirtyStore.sub(idx);
      dirtyStore.upd(idx, update(dirtyLine, way, dirty));
    endaction
  endfunction

  function Action writeLine(DCacheWayIdx way, DCacheIndex idx, DCacheLine line);
    action
      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        if (fromInteger(w) == way) begin
          for (Integer b = 0; b < valueOf(DCacheLineWords); b = b + 1) begin
            dataStore[w][b].put(1'b1, idx, line[b]);
          end
        end
      end
    endaction
  endfunction

  function Action writeWord(DCacheWayIdx way, DCacheIndex idx, DCacheWordSel wsel, Data data);
    action
      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        if (fromInteger(w) == way) begin
          for (Integer b = 0; b < valueOf(DCacheLineWords); b = b + 1) begin
            if (fromInteger(b) == wsel) begin
              dataStore[w][b].put(1'b1, idx, data);
            end
          end
        end
      end
    endaction
  endfunction

  function Vector#(DCacheWays, DCacheTagValid) currentTagValids;
    Vector#(DCacheWays, DCacheTagValid) ret = replicate(DCacheTagValid{valid: False, tag: 0});
    for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
      ret = update(ret, fromInteger(w), unpackDCacheTagValid(tagValidStore[w].read));
    end
    return ret;
  endfunction

  function Vector#(DCacheWays, DCacheLine) currentLines(DCacheIndex idx);
    Vector#(DCacheWays, DCacheLine) ret = replicate(replicate(0));
    for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
      DCacheLine line = replicate(0);
      for (Integer b = 0; b < valueOf(DCacheLineWords); b = b + 1) begin
        line = update(line, fromInteger(b), dataStore[w][b].read);
      end
      ret = update(ret, fromInteger(w), line);
    end
    if (writeBufferValid && writeBuffer.idx == idx) begin
      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        if (fromInteger(w) == writeBuffer.way) begin
          DCacheLine line = ret[w];
          line = update(line, writeBuffer.wsel, writeBuffer.data);
          ret = update(ret, fromInteger(w), line);
        end
      end
    end
    return ret;
  endfunction

  `ifdef CONFIG_TRACE_PERFORMANCE
  rule countMissCycles (state != Ready);
    perf_dcache_miss_cycle();
  endrule
  `endif

  rule doInit (state == Init);
    writeTagValid(initWay, initIdx, DCacheTagValid{valid: False, tag: 0});
    if (initWay == 0) begin
      dirtyStore.upd(initIdx, replicate(False));
    end

    Bool lastWay = initWay == fromInteger(valueOf(DCacheWays) - 1);
    Bool lastIdx = initIdx == fromInteger(valueOf(DCacheSets) - 1);
    if (lastWay && lastIdx) begin
      state <= Ready;
    end else if (lastWay) begin
      initWay <= 0;
      initIdx <= initIdx + 1;
    end else begin
      initWay <= initWay + 1;
    end
  endrule

  function Action doCacopReq(
      MemReq r,
      Vector#(DCacheWays, DCacheTagValid) tagValids,
      Vector#(DCacheWays, DCacheLine) lines,
      DCacheDirtyLine dirtyLine);
    action
      DCacheOpType opType = r.cacheOp[4:3];
      let idx = getDIndex(r.addr);
      let tag = getDTag(r.paddr);
      let way = getDCacopWaySel(r.addr);

      Bool hit = False;
      DCacheWayIdx hitWay = 0;
      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        if (tagValids[w].valid && tagValids[w].tag == tag) begin
          hit = True;
          hitWay = fromInteger(w);
        end
      end

      if (r.cacheOp[2:0] != 3'b001) begin
        respQ.enq(DCacheResp{data: 0});
        state <= Ready;
      end else if (opType == 2'b00) begin
        writeTagValid(way, idx, DCacheTagValid{valid: False, tag: 0});
        writeDirty(idx, way, False);
        if (writeBufferValid && writeBuffer.idx == idx && writeBuffer.way == way) begin
          writeBufferValid <= False;
        end
        if (llValid && getDBlockBase(llAddr) == getDBlockBase(r.paddr)) begin
          llValid <= False;
        end
        respQ.enq(DCacheResp{data: 0});
        state <= Ready;
      end else begin
        Bool targetValid = False;
        Bool targetDirty = False;
        DCacheWayIdx targetWay = way;
        Addr targetBlockAddr = getDBlockBase(r.paddr);

        if (opType == 2'b01) begin
          targetValid = tagValids[way].valid;
          targetDirty = dirtyLine[way];
        end else if (opType == 2'b10 && hit) begin
          targetWay = hitWay;
          targetValid = True;
          targetDirty = dirtyLine[hitWay];
          Bit#(DCacheOffsetSz) zeroOff = 0;
          targetBlockAddr = { tagValids[hitWay].tag, idx, zeroOff };
        end

        if (!targetValid) begin
          respQ.enq(DCacheResp{data: 0});
          state <= Ready;
        end else if (targetDirty) begin
          Bit#(DCacheOffsetSz) zeroOff = 0;
          wbLine <= lines[targetWay];
          awQ.enq(AxiWriteAddr{
            addr: { tagValids[targetWay].tag, idx, zeroOff },
            len: fromInteger(valueOf(DCacheLineWords) - 1),
            size: 3'd2,
            burst: AxiBurstIncr
          });
          beatIdx <= 0;
          cacheMaintWait <= True;
          cacheMaintIdx <= idx;
          cacheMaintWay <= targetWay;
          cacheMaintBlockAddr <= targetBlockAddr;
          state <= SendWbData;
        end else begin
          writeTagValid(targetWay, idx, DCacheTagValid{valid: False, tag: 0});
          writeDirty(idx, targetWay, False);
          if (writeBufferValid && writeBuffer.idx == idx && writeBuffer.way == targetWay) begin
            writeBufferValid <= False;
          end
          if (llValid && getDBlockBase(llAddr) == targetBlockAddr) begin
            llValid <= False;
          end
          respQ.enq(DCacheResp{data: 0});
          state <= Ready;
        end
      end
    endaction
  endfunction

  rule drainWriteBuffer (state == Ready && !reqQ.notEmpty && writeBufferValid);
    writeWord(writeBuffer.way, writeBuffer.idx, writeBuffer.wsel, writeBuffer.data);
    writeBufferValid <= False;
  endrule

  rule doIssueLookup (state == Ready && reqQ.notEmpty && !writeBufferValid);
    let r = reqQ.first;
    reqQ.deq;

    if (!r.useCache && r.op != Barrier && r.op != Cacop) begin
      if (r.op == Sc && !(llValid && llAddr == r.paddr)) begin
        respQ.enq(DCacheResp{data: scFail});
        llValid <= False;
      end else begin
        missReq <= r;
`ifdef CONFIG_TRACE_PERFORMANCE
        perf_dcache_miss();
`endif
        state <= SendUncacheReq;
      end
    end else begin
      lookupReq <= r;
      issueRead(getDIndex(r.addr));
      state <= LookupResp;
    end
  endrule

  rule doLookupResp (state == LookupResp);
    let r = lookupReq;
    let tag = getDTag(r.paddr);
    let idx = getDIndex(r.addr);
    let wsel = getDWordSel(r.addr);
    let tagValids = currentTagValids;
    let lines = currentLines(idx);
    let dirtyLine = currentDirties(idx);

    if (r.op == Barrier) begin
      Bool hit = False;
      Data hitData = 0;
      DCacheWayIdx hitWay = 0;
      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        if (tagValids[w].valid && tagValids[w].tag == tag) begin
          hit = True;
          hitData = lines[w][wsel];
          hitWay = fromInteger(w);
        end
      end
      if (hit && dirtyLine[hitWay]) begin
        missReq <= MemReq{
          op: St,
          addr: r.addr,
          paddr: r.paddr,
          useCache: False,
          data: hitData,
          byteEn: 4'b1111,
          cacheOp: 5'b0
        };
        fenceFlushWait <= True;
        state <= SendUncacheReq;
      end else begin
        // Barrier completes immediately if no dirty line needs writeback.
        respQ.enq(DCacheResp{data: 0});
        fenceFlushWait <= False;
        state <= Ready;
      end
    end else if (r.op == Cacop) begin
      doCacopReq(r, tagValids, lines, dirtyLine);
    end else begin
      Bool         hit = False;
      Data         hitData = 0;
      DCacheLine   hitLine = replicate(0);
      DCacheWayIdx hitWay = 0;

      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        if (tagValids[w].valid && tagValids[w].tag == tag) begin
          hit = True;
          hitData = lines[w][wsel];
          hitLine = lines[w];
          hitWay = fromInteger(w);
        end
      end

      if (hit) begin
        replacer.access(idx, hitWay);

        case (r.op)
          Ld: begin
            respQ.enq(DCacheResp{data: hitData});
          end
          Ll: begin
            respQ.enq(DCacheResp{data: hitData});
            llValid <= True;
            llAddr <= r.paddr;
          end
          Sc: begin
            if (llValid && llAddr == r.paddr)
              respQ.enq(DCacheResp{data: scSucc});
            else
              respQ.enq(DCacheResp{data: scFail});
            llValid <= False;
          end
          default: begin end
        endcase

        Bool doWrite = (r.op == St) ||
          (r.op == Sc && llValid && llAddr == r.paddr);
        if (doWrite) begin
          Data mergedWord = applyByteMask(hitLine[wsel], r.data, r.byteEn);
          writeBuffer <= DCacheWriteBuffer{
            idx: idx,
            way: hitWay,
            wsel: wsel,
            data: mergedWord
          };
          writeBufferValid <= True;
          writeDirty(idx, hitWay, True);
          if (r.op == St) begin
            respQ.enq(DCacheResp{data: 0});
          end
        end

        if (r.op == St && llValid && llAddr == r.paddr)
          llValid <= False;
        state <= Ready;
      end else begin
        if (r.op == Sc) begin
          respQ.enq(DCacheResp{data: scFail});
          llValid <= False;
          state <= Ready;
        end else begin
          missReq <= r;
          let way = replacer.replace(idx);
          victimWay <= way;
`ifdef CONFIG_TRACE_PERFORMANCE
          perf_dcache_miss();
`endif
          if (tagValids[way].valid && dirtyLine[way]) begin
            Bit#(DCacheOffsetSz) zeroOff = 0;
            wbLine <= lines[way];
            awQ.enq(AxiWriteAddr{
              addr: { tagValids[way].tag, idx, zeroOff },
              len: fromInteger(valueOf(DCacheLineWords) - 1),
              size: 3'd2,
              burst: AxiBurstIncr
            });
            beatIdx <= 0;
            state <= SendWbData;
          end else begin
            state <= SendFillAddr;
          end
        end
      end
    end
  endrule

  rule doSendWbData (state == SendWbData && wQ.notFull);
    Bit#(DCacheWordSelSz) widx = truncate(beatIdx);
    Bit#(8) nextBeat = beatIdx + 1;
    Bool last = (nextBeat == fromInteger(valueOf(DCacheLineWords)));
    wQ.enq(AxiWriteData{
      data: wbLine[widx],
      strb: '1,
      last: last
    });
    beatIdx <= nextBeat;
    if (last) begin
      state <= WaitWbResp;
    end
  endrule

  rule doWaitWbResp (state == WaitWbResp && bQ.notEmpty);
    bQ.deq;
    if (cacheMaintWait) begin
      writeTagValid(cacheMaintWay, cacheMaintIdx, DCacheTagValid{valid: False, tag: 0});
      writeDirty(cacheMaintIdx, cacheMaintWay, False);
      if (writeBufferValid && writeBuffer.idx == cacheMaintIdx &&
          writeBuffer.way == cacheMaintWay) begin
        writeBufferValid <= False;
      end
      if (llValid && getDBlockBase(llAddr) == cacheMaintBlockAddr) begin
        llValid <= False;
      end
      cacheMaintWait <= False;
      if (!squashPending) begin
        respQ.enq(DCacheResp{data: 0});
      end
      squashPending <= False;
      state <= Ready;
    end else begin
      state <= SendFillAddr;
    end
  endrule

  rule doSendFillAddr (state == SendFillAddr);
    arQ.enq(AxiReadAddr{
      addr: getDBlockBase(missReq.paddr),
      len: fromInteger(valueOf(DCacheLineWords) - 1),
      size: 3'd2,
      burst: AxiBurstIncr
    });
    beatIdx <= 0;
    fillLine <= replicate(0);
    state <= WaitFillResp;
  endrule

  rule doWaitFillResp (state == WaitFillResp && rQ.notEmpty);
    let beat = rQ.first;
    rQ.deq;

    let r = missReq;
    let idx = getDIndex(r.addr);
    let tag = getDTag(r.paddr);
    let wsel = getDWordSel(r.addr);
    let way = victimWay;

    Bit#(DCacheWordSelSz) lineIdx = truncate(beatIdx);
    DCacheLine nextLine = update(fillLine, lineIdx, beat.data);
    Bit#(8) nextBeat = beatIdx + 1;
    fillLine <= nextLine;
    beatIdx <= nextBeat;

    if (beat.last || nextBeat == fromInteger(valueOf(DCacheLineWords))) begin
      writeTagValid(way, idx, DCacheTagValid{valid: True, tag: tag});

      case (r.op)
        Ld: begin
          if (!squashPending) begin
            respQ.enq(DCacheResp{data: nextLine[wsel]});
          end
          writeLine(way, idx, nextLine);
          writeDirty(idx, way, False);
        end
        St: begin
          Data mergedWord = applyByteMask(nextLine[wsel], r.data, r.byteEn);
          DCacheLine newLine = update(nextLine, wsel, mergedWord);
          writeLine(way, idx, newLine);
          writeDirty(idx, way, True);
          if (!squashPending) begin
            respQ.enq(DCacheResp{data: 0});
          end
        end
        Ll: begin
          if (!squashPending) begin
            respQ.enq(DCacheResp{data: nextLine[wsel]});
            llValid <= True;
            llAddr <= r.paddr;
          end
          writeLine(way, idx, nextLine);
          writeDirty(idx, way, False);
        end
        default: begin
          writeLine(way, idx, nextLine);
          writeDirty(idx, way, False);
        end
      endcase

      replacer.access(idx, way);
      squashPending <= False;
      state <= Ready;
    end
  endrule

  rule doSendUncacheReq (state == SendUncacheReq);
    let r = missReq;
    if (r.op == Ld || r.op == Ll) begin
      arQ.enq(AxiReadAddr{
        addr: r.paddr,
        len: 'b0,
        size: 3'd2,
        burst: AxiBurstFixed
      });
    end else if (r.op == St || r.op == Sc) begin
      awQ.enq(AxiWriteAddr{
        addr: r.paddr,
        len: 'b0,
        size: 3'd2,
        burst: AxiBurstFixed
      });
      wQ.enq(AxiWriteData{
        data: r.data,
        strb: r.byteEn,
        last: True
      });
    end
    state <= WaitUncacheResp;
  endrule

  rule doWaitUncacheLoadResp (state == WaitUncacheResp &&
      (missReq.op == Ld || missReq.op == Ll) &&
      rQ.notEmpty);
    let r = missReq;
    let beat = rQ.first;
    rQ.deq;
    dynamicAssert(beat.resp == AxiRespOkay ||
                  beat.resp == AxiRespExOkay, "read resp has fault");
    if (!squashPending) begin
      respQ.enq(DCacheResp{data: beat.data});
      if (r.op == Ll) begin
        llValid <= True;
        llAddr <= r.paddr;
      end
    end
    squashPending <= False;
    state <= Ready;
  endrule

  rule doWaitUncacheStoreResp (state == WaitUncacheResp &&
      (missReq.op == St || missReq.op == Sc) &&
      bQ.notEmpty);
    let r = missReq;
    let beat = bQ.first;
    bQ.deq;
    dynamicAssert(beat.resp == AxiRespOkay ||
                  beat.resp == AxiRespExOkay, "write resp has fault");
    if (!squashPending) begin
      respQ.enq(DCacheResp{data: r.op == Sc ? scSucc : 0});
    end
    if (r.op == Sc || (r.op == St && llValid && llAddr == r.paddr)) begin
      llValid <= False;
    end
    if (fenceFlushWait) begin
      fenceFlushWait <= False;
    end
    squashPending <= False;
    state <= Ready;
  endrule

  method Action req(MemReq r);
    reqQ.enq(r);
  endmethod

  method Action cacop(MemReq r)
      if (state == Ready && !reqQ.notEmpty && respQ.notFull && !writeBufferValid);
    lookupReq <= r;
    issueRead(getDIndex(r.addr));
    state <= LookupResp;
  endmethod

  method ActionValue#(DCacheResp) resp;
    let d = respQ.first;
    respQ.deq;
    return d;
  endmethod

  method Action squash(Bool clearLl);
    reqQ.clear();
    respQ.clear();
    if (clearLl) begin
      llValid <= False;
    end
    if (state != Ready) begin
      squashPending <= True;
    end
    writeBufferValid <= False;
    fenceFlushWait <= False;
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

    method Bool wrAddrValid = awQ.notEmpty;

    method ActionValue#(AxiWriteAddr) wrAddr;
      let x = awQ.first;
      awQ.deq;
      return x;
    endmethod

    method Bool wrDataValid = wQ.notEmpty;

    method ActionValue#(AxiWriteData) wrData;
      let x = wQ.first;
      wQ.deq;
      return x;
    endmethod

    method Action wrResp(AxiWriteResp r);
      bQ.enq(r);
    endmethod
  endinterface
endmodule
