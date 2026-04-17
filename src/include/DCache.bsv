import Types::*;
import ProcTypes::*;
import MemTypes::*;
import AxiTypes::*;
import Fifo::*;
import Vector::*;
import Param::*;
import Assert::*;
`include "Autoconf.bsv"

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

function DCacheTag     getDTag(Addr a) = truncateLSB(a);
function DCacheIndex   getDIndex(Addr a) = truncate(a >> valueOf(DCacheOffsetSz));
function DCacheWordSel getDWordSel(Addr a) = truncate(a >> 2);
function DCacheWayIdx  getDWaySel(Addr a) = truncate(a >> valueOf(DCacheWaySelOffSz));
function Addr getDBlockBase(Addr a);
  Bit#(TSub#(AddrSz, DCacheOffsetSz)) upper = truncateLSB(a);
  Bit#(DCacheOffsetSz) lower = 0;
  return { upper, lower };
endfunction
function Bool isUncacheAddr(Addr a);
  return (truncateLSB(a) == uncached_base);
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

function Bool dcDbgWatchAddr(Addr a);
  return getDBlockBase(a) == 32'h000d2aa0;
endfunction

interface DCache;
  method Action req(MemReq r);
  method ActionValue#(Data) resp;
  interface AxiMemMaster axiMem;
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

typedef enum {
  Ready,
  StartMiss,
  SendWbData,
  WaitWbResp,
  SendFillAddr,
  WaitFillResp,
  SendUncacheReq,
  WaitUncacheResp
} DCacheState deriving(Bits, Eq);

(* synthesize *)
module mkDCache(DCache);
  Vector#(DCacheSets, Vector#(DCacheWays, Reg#(DCacheTag)))   tagStore <- replicateM(replicateM(mkRegU));
  Vector#(DCacheSets, Vector#(DCacheWays, Reg#(DCacheLine)))  dataStore <- replicateM(replicateM(mkRegU));
  Vector#(DCacheSets, Vector#(DCacheWays, Reg#(Bool)))        validStore <- replicateM(replicateM(mkReg(False)));
  Vector#(DCacheSets, Vector#(DCacheWays, Reg#(Bool)))        dirtyStore <- replicateM(replicateM(mkReg(False)));

  Reg#(DCacheState) state <- mkReg(Ready);
  Reg#(MemReq)      missReq <- mkRegU;
  Reg#(DCacheWayIdx) victimWay <- mkRegU;
  Reg#(DCacheLine)   wbLine <- mkRegU;
  Reg#(Bit#(8))      beatIdx <- mkRegU;
  Reg#(DCacheLine)   fillLine <- mkRegU;

  Reg#(Bool) lrValid <- mkReg(False);
  Reg#(Addr) lrAddr <- mkRegU;
  Reg#(Bool) fenceFlushWait <- mkReg(False);
  Reg#(Bool) cacheMaintWait <- mkReg(False);
  Reg#(DCacheIndex) cacheMaintIdx <- mkRegU;
  Reg#(DCacheWayIdx) cacheMaintWay <- mkRegU;
  Reg#(Addr) cacheMaintBlockAddr <- mkRegU;

  Fifo#(2, MemReq) reqQ <- mkCFFifo;
  Fifo#(2, Data)   respQ <- mkCFFifo;

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

  rule doLookup (state == Ready);
    let r = reqQ.first;
    reqQ.deq;

    if (r.op == Barrier) begin
      let tag = getDTag(r.addr);
      let idx = getDIndex(r.addr);
      let wsel = getDWordSel(r.addr);
      Bool hit = False;
      Data hitData = 0;
      DCacheWayIdx hitWay = 0;
      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        if (validStore[idx][w] && tagStore[idx][w] == tag) begin
          hit = True;
          hitData = dataStore[idx][w][wsel];
          hitWay = fromInteger(w);
        end
      end
`ifdef CONFIG_MTRACE
      $fwrite(stdout, "[DCDBG] BARRIER addr:%x hit:%0d dirty:%0d data:%x\n",
        r.addr, pack(hit), pack(hit && dirtyStore[idx][hitWay]), hitData);
`endif
      if (hit && dirtyStore[idx][hitWay]) begin
`ifdef CONFIG_MTRACE
        $fwrite(stdout, "[DCDBG] BARRIER-WB addr:%x data:%x\n", r.addr, hitData);
`endif
        missReq <= MemReq{
          op: St,
          addr: r.addr,
          data: hitData,
          byteEn: 4'b1111,
          cacheOp: 5'b0
        };
        fenceFlushWait <= True;
        state <= SendUncacheReq;
      end else begin
        // Barrier completes immediately if no dirty line needs writeback.
        respQ.enq(0);
        fenceFlushWait <= False;
      end
    end else if (r.op == Cacop) begin
      DCacheOpType opType = r.cacheOp[4:3];
      let idx = getDIndex(r.addr);
      let tag = getDTag(r.addr);
      let way = getDWaySel(r.addr);
      let ctag = r.data;

      Bool hit = False;
      DCacheWayIdx hitWay = 0;
      for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
        if (validStore[idx][w] && tagStore[idx][w] == tag) begin
          hit = True;
          hitWay = fromInteger(w);
        end
      end

      if (r.cacheOp[2:0] != 3'b001) begin
        respQ.enq(0);
      end else if (opType == 2'b00) begin
        // This core uses an implementation-defined CTAG layout:
        // ctag[0] drives valid, ctag[1] drives dirty, upper bits drive tag.
        tagStore[idx][way] <= truncateLSB(ctag);
        validStore[idx][way] <= ctag[0] == 1'b1;
        dirtyStore[idx][way] <= (ctag[0] == 1'b1) && (ctag[1] == 1'b1);
        if (lrValid && getDBlockBase(lrAddr) == getDBlockBase(r.addr)) begin
          lrValid <= False;
        end
        respQ.enq(0);
      end else begin
        Bool targetValid = False;
        Bool targetDirty = False;
        DCacheWayIdx targetWay = way;
        Addr targetBlockAddr = getDBlockBase(r.addr);

        if (opType == 2'b01) begin
          targetValid = validStore[idx][way];
          targetDirty = dirtyStore[idx][way];
        end else if (opType == 2'b10 && hit) begin
          targetWay = hitWay;
          targetValid = True;
          targetDirty = dirtyStore[idx][hitWay];
          Bit#(DCacheOffsetSz) zeroOff = 0;
          targetBlockAddr = { tagStore[idx][hitWay], idx, zeroOff };
        end

        if (!targetValid) begin
          respQ.enq(0);
        end else if (targetDirty) begin
          Bit#(DCacheOffsetSz) zeroOff = 0;
          wbLine <= dataStore[idx][targetWay];
          awQ.enq(AxiWriteAddr{
            addr: { tagStore[idx][targetWay], idx, zeroOff },
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
          validStore[idx][targetWay] <= False;
          dirtyStore[idx][targetWay] <= False;
          if (lrValid && getDBlockBase(lrAddr) == targetBlockAddr) begin
            lrValid <= False;
          end
          respQ.enq(0);
        end
      end
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

`ifdef CONFIG_MTRACE
      if (dcDbgWatchAddr(r.addr)) begin
        $fwrite(stdout,
          "[DCDBG] LOOKUP op:%0d addr:%x idx:%0d tag:%x wsel:%0d hit:%0d way:%0d line:%x_%x_%x_%x\n",
          pack(r.op), r.addr, idx, tag, wsel, pack(hit), hitWay,
          hitLine[3], hitLine[2], hitLine[1], hitLine[0]);
      end
`endif

      if (isUncacheAddr(r.addr)) begin
        missReq <= r;
        state <= SendUncacheReq;
      end else if (hit) begin
        replacer.access(idx, hitWay);

        case (r.op)
          Ld: begin
`ifdef CONFIG_MTRACE
            if (dcDbgWatchAddr(r.addr)) begin
              $fwrite(stdout, "[DCDBG] LD-HIT addr:%x data:%x\n", r.addr, hitData);
            end
`endif
            respQ.enq(hitData);
          end
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
          Data mergedWord = applyByteMask(hitLine[wsel], r.data, r.byteEn);
          DCacheLine newLine = update(hitLine, wsel, mergedWord);
`ifdef CONFIG_MTRACE
          if (dcDbgWatchAddr(r.addr)) begin
            $fwrite(stdout,
              "[DCDBG] ST-HIT addr:%x old:%x new:%x line:%x_%x_%x_%x -> %x_%x_%x_%x\n",
              r.addr, hitLine[wsel], mergedWord,
              hitLine[3], hitLine[2], hitLine[1], hitLine[0],
              newLine[3], newLine[2], newLine[1], newLine[0]);
          end
`endif
          for (Integer w = 0; w < valueOf(DCacheWays); w = w + 1) begin
            if (fromInteger(w) == hitWay) begin
              dataStore[idx][w] <= newLine;
              dirtyStore[idx][w] <= True;
            end
          end
          if (r.op == St) begin
            respQ.enq(0);
          end
        end

        if (r.op == St && lrValid && lrAddr == r.addr)
          lrValid <= False;
      end else begin
        if (r.op == Sc) begin
          respQ.enq(scFail);
          lrValid <= False;
        end else begin
`ifdef CONFIG_MTRACE
          if (dcDbgWatchAddr(r.addr)) begin
            $fwrite(stdout, "[DCDBG] MISS op:%0d addr:%x idx:%0d tag:%x\n",
              pack(r.op), r.addr, idx, tag);
          end
`endif
          missReq <= r;
          state <= StartMiss;
        end
      end
    end
  endrule

  rule doStartMiss (state == StartMiss);
    let idx = getDIndex(missReq.addr);
    let way = replacer.replace(idx);
    victimWay <= way;
    Bit#(DCacheOffsetSz) zeroOff = 0;
    Addr victimAddr = {tagStore[idx][way], idx, zeroOff};

`ifdef CONFIG_MTRACE
    if (dcDbgWatchAddr(missReq.addr) || dcDbgWatchAddr(victimAddr)) begin
      $fwrite(stdout,
        "[DCDBG] START-MISS req:%x op:%0d victimWay:%0d victimAddr:%x valid:%0d dirty:%0d victimLine:%x_%x_%x_%x\n",
        missReq.addr, pack(missReq.op), way, victimAddr,
        pack(validStore[idx][way]), pack(dirtyStore[idx][way]),
        dataStore[idx][way][3], dataStore[idx][way][2],
        dataStore[idx][way][1], dataStore[idx][way][0]);
    end
`endif

    if (validStore[idx][way] && dirtyStore[idx][way]) begin
      wbLine <= dataStore[idx][way];
      awQ.enq(AxiWriteAddr{
        addr: {tagStore[idx][way], idx, zeroOff},
        len: fromInteger(valueOf(DCacheLineWords) - 1),
        size: 3'd2,
        burst: AxiBurstIncr
      });
      beatIdx <= 0;
      state <= SendWbData;
    end
    else begin
      state <= SendFillAddr;
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
      validStore[cacheMaintIdx][cacheMaintWay] <= False;
      dirtyStore[cacheMaintIdx][cacheMaintWay] <= False;
      if (lrValid && getDBlockBase(lrAddr) == cacheMaintBlockAddr) begin
        lrValid <= False;
      end
      cacheMaintWait <= False;
      respQ.enq(0);
      state <= Ready;
    end else begin
      state <= SendFillAddr;
    end
  endrule

  rule doSendFillAddr (state == SendFillAddr);
    arQ.enq(AxiReadAddr{
      addr: getDBlockBase(missReq.addr),
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
    let tag = getDTag(r.addr);
    let wsel = getDWordSel(r.addr);
    let way = victimWay;

    Bit#(DCacheWordSelSz) lineIdx = truncate(beatIdx);
    DCacheLine nextLine = update(fillLine, lineIdx, beat.data);
    Bit#(8) nextBeat = beatIdx + 1;
    fillLine <= nextLine;
    beatIdx <= nextBeat;

    if (beat.last || nextBeat == fromInteger(valueOf(DCacheLineWords))) begin
      tagStore[idx][way] <= tag;
      validStore[idx][way] <= True;

      case (r.op)
        Ld: begin
`ifdef CONFIG_MTRACE
          if (dcDbgWatchAddr(r.addr)) begin
            $fwrite(stdout,
              "[DCDBG] FILL-LD addr:%x line:%x_%x_%x_%x resp:%x\n",
              r.addr, nextLine[3], nextLine[2], nextLine[1], nextLine[0], nextLine[wsel]);
          end
`endif
          respQ.enq(nextLine[wsel]);
          dataStore[idx][way] <= nextLine;
          dirtyStore[idx][way] <= False;
        end
        St: begin
          Data mergedWord = applyByteMask(nextLine[wsel], r.data, r.byteEn);
          DCacheLine newLine = update(nextLine, wsel, mergedWord);
`ifdef CONFIG_MTRACE
          if (dcDbgWatchAddr(r.addr)) begin
            $fwrite(stdout,
              "[DCDBG] FILL-ST addr:%x line:%x_%x_%x_%x -> %x_%x_%x_%x\n",
              r.addr,
              nextLine[3], nextLine[2], nextLine[1], nextLine[0],
              newLine[3], newLine[2], newLine[1], newLine[0]);
          end
`endif
          dataStore[idx][way] <= newLine;
          dirtyStore[idx][way] <= True;
          respQ.enq(0);
        end
        Lr: begin
          respQ.enq(nextLine[wsel]);
          dataStore[idx][way] <= nextLine;
          dirtyStore[idx][way] <= False;
          lrValid <= True;
          lrAddr <= r.addr;
        end
        default: begin
          dataStore[idx][way] <= nextLine;
          dirtyStore[idx][way] <= False;
        end
      endcase

      replacer.access(idx, way);
      state <= Ready;
    end
  endrule

  rule doSendUncacheReq (state == SendUncacheReq);
    let r = missReq;
    if (r.op == Ld) begin
      arQ.enq(AxiReadAddr{
        addr: r.addr,
        len: 'b0,
        size: 3'd2,
        burst: AxiBurstFixed
      });
    end else if (r.op == St) begin
      awQ.enq(AxiWriteAddr{
        addr: r.addr,
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

  rule doWaitUncacheResp (state == WaitUncacheResp && (
    ((missReq.op == Ld) && rQ.notEmpty) || 
    ((missReq.op == St) && bQ.notEmpty)));
    let r = missReq;
    if (r.op == Ld) begin
      let beat = rQ.first;
      rQ.deq;
      dynamicAssert(beat.resp == AxiRespOkay ||
                    beat.resp == AxiRespExOkay, "read resp has fault");
      respQ.enq(beat.data);
    end else if (r.op == St) begin
      let beat = bQ.first;
      bQ.deq;
      dynamicAssert(beat.resp == AxiRespOkay ||
                    beat.resp == AxiRespExOkay, "write resp has fault");
      respQ.enq(0);
      if (fenceFlushWait) begin
        fenceFlushWait <= False;
      end
    end
    state <= Ready;
  endrule

  method Action req(MemReq r);
    reqQ.enq(r);
  endmethod

  method ActionValue#(Data) resp;
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
