import Vector::*;
import Fifo::*;

import Types::*;
import ProcTypes::*;
import MemTypes::*;
import CacheTypes::*;
import MemUtil::*;
import Core::*;
import MemoryService::*;

typedef 20 TbWordAddrSz;
typedef Bit#(TbWordAddrSz) TbWordAddr;
typedef 1000000 TbMaxCycles;

typedef enum {
  WideMemIdle,
  WideMemSendReadReq,
  WideMemWaitReadResp,
  WideMemSendWriteReq
} TbWideMemState deriving(Bits, Eq);

import "BDPI" function ActionValue#(Bit#(64)) c_createTbMem(Bit#(32)
  wordAddrWidth);
import "BDPI" function Action c_loadTbMem(Bit#(64) memPtr);
import "BDPI" function ActionValue#(Data) c_readTbMem(Bit#(64) memPtr, Bit#(32)
  wordAddr);
import "BDPI" function Action c_writeTbMem(Bit#(64) memPtr, Bit#(32) wordAddr,
  Data d);

function Bool inTbMemRange(Bit#(TSub#(AddrSz, 2)) wordAddr);
  TbWordAddr narrowAddr = truncate(wordAddr);
  return zeroExtend(narrowAddr) == wordAddr;
endfunction

function Bool inTbMemRange32(Bit#(32) wordAddr);
  Bit#(TSub#(AddrSz, 2)) addrLow = truncate(wordAddr);
  Bool widthFits = zeroExtend(addrLow) == wordAddr;
  return widthFits && inTbMemRange(addrLow);
endfunction

function Bit#(TSub#(AddrSz, 2)) getLineBaseWordAddr(Addr addr);
  Bit#(TSub#(AddrSz, 2)) baseWordAddr = truncateLSB(addr);
  for (Integer i = 0; i < valueOf(TLog#(CacheLineWords)); i = i + 1) begin
    baseWordAddr[i] = 0;
  end
  return baseWordAddr;
endfunction

module mkBdpiMemoryService(MemoryService);
  Fifo#(32, Data) readRespQ <- mkCFFifo;
  Reg#(Bit#(64)) memPtr <- mkReg(0);
  Reg#(Bool) memReady <- mkReg(False);

  rule initMem (!memReady);
    let ptr <- c_createTbMem(fromInteger(valueOf(TbWordAddrSz)));
    if (ptr == 0) begin
      $fwrite(stderr, "TB: failed to create simulation memory\n");
      $finish(1);
    end
    c_loadTbMem(ptr);
    memPtr <= ptr;
    memReady <= True;
  endrule

  method Action writeReq(Bit#(32) wordAddr, Data d) if (memReady);
    if (!inTbMemRange32(wordAddr)) begin
      $fwrite(stderr, "TB: write word address out of range: %08x\n", wordAddr);
      $finish(1);
    end
    else begin
      c_writeTbMem(memPtr, wordAddr, d);
    end
  endmethod

  method Action readReq(Bit#(32) wordAddr) if (memReady);
    if (!inTbMemRange32(wordAddr)) begin
      $fwrite(stderr, "TB: read word address out of range: %08x\n", wordAddr);
      $finish(1);
    end
    else begin
      let d <- c_readTbMem(memPtr, wordAddr);
      readRespQ.enq(d);
    end
  endmethod

  method Bool readRespValid = readRespQ.notEmpty;

  method ActionValue#(Data) readResp if (readRespQ.notEmpty);
    let d = readRespQ.first;
    readRespQ.deq;
    return d;
  endmethod
endmodule

module mkTbWideMem#(MemoryService memSvc)(WideMem);
  Fifo#(2, WideMemReq) reqQ <- mkCFFifo;
  Fifo#(2, CacheLine) respQ <- mkCFFifo;

  Reg#(TbWideMemState) state <- mkReg(WideMemIdle);
  Reg#(WideMemReq) activeReq <- mkRegU;
  Reg#(Bit#(TSub#(AddrSz, 2))) baseWordAddr <- mkRegU;
  Reg#(CacheWordSelect) wordIdx <- mkReg(0);
  Reg#(CacheLine) readLine <- mkReg(replicate(0));

  rule startReq (state == WideMemIdle && reqQ.notEmpty);
    let r = reqQ.first;
    let base = getLineBaseWordAddr(r.addr);

    if (!inTbMemRange(base)) begin
      $fwrite(stderr, "TB: wide memory access out of range: %08x\n", r.addr);
      $finish(1);
    end
    else begin
      reqQ.deq;
      activeReq <= r;
      baseWordAddr <= base;
      wordIdx <= 0;

      if (r.write_en == 0) begin
        state <= WideMemSendReadReq;
      end
      else begin
        state <= WideMemSendWriteReq;
      end
    end
  endrule

  rule doSendReadReq (state == WideMemSendReadReq);
    Bit#(32) addr = zeroExtend(baseWordAddr) + zeroExtend(wordIdx);
    memSvc.readReq(addr);

    if (wordIdx == fromInteger(valueOf(CacheLineWords) - 1)) begin
      wordIdx <= 0;
      state <= WideMemWaitReadResp;
    end
    else begin
      wordIdx <= wordIdx + 1;
    end
  endrule

  rule doWaitReadResp (state == WideMemWaitReadResp && memSvc.readRespValid);
    let d <- memSvc.readResp;
    CacheLine nextLine = update(readLine, wordIdx, d);
    readLine <= nextLine;

    if (wordIdx == fromInteger(valueOf(CacheLineWords) - 1)) begin
      respQ.enq(nextLine);
      wordIdx <= 0;
      state <= WideMemIdle;
    end
    else begin
      wordIdx <= wordIdx + 1;
    end
  endrule

  rule doSendWriteReq (state == WideMemSendWriteReq);
    if (activeReq.write_en[wordIdx] == 1) begin
      Bit#(32) addr = zeroExtend(baseWordAddr) + zeroExtend(wordIdx);
      memSvc.writeReq(addr, activeReq.data[wordIdx]);
    end

    if (wordIdx == fromInteger(valueOf(CacheLineWords) - 1)) begin
      wordIdx <= 0;
      state <= WideMemIdle;
    end
    else begin
      wordIdx <= wordIdx + 1;
    end
  endrule

  method Action req(WideMemReq r);
    reqQ.enq(r);
  endmethod

  method ActionValue#(CacheLine) resp;
    let line = respQ.first;
    respQ.deq;
    return line;
  endmethod

  method Bool respValid = respQ.notEmpty;
endmodule

(* synthesize *)
module mkTb(Empty);
  Reg#(Bool) started <- mkReg(False);
  Reg#(Bit#(16)) printIntLow <- mkReg(0);
  Reg#(Bit#(64)) cycles <- mkReg(0);

  MemoryService memSvc <- mkBdpiMemoryService;
  WideMem wideMemWrapper <- mkTbWideMem(memSvc);
  SplitWideMem2 splitWideMem <- mkSplitWideMem2(started, wideMemWrapper);
  Core core <- mkCore(splitWideMem.iMem, splitWideMem.dMem);

  rule boot (!started);
    started <= True;
    core.hostToCpu(0);
  endrule

  rule countCycles (started);
    cycles <= cycles + 1;
    if (cycles == fromInteger(valueOf(TbMaxCycles) - 1)) begin
      $fwrite(stderr, "TB: timeout after %0d cycles\n", valueOf(TbMaxCycles));
      $finish(1);
    end
  endrule

  rule drainCpuToHost (started && core.cpuToHostValid);
    let msg <- core.cpuToHost;
    case (msg.c2hType)
      ExitCode: begin
        Bit#(32) code = zeroExtend(msg.data);
        $display("TB: exit code %0d after %0d cycles", code, cycles);
        $finish(0);
      end
      PrintChar: begin
        Bit#(8) char = truncate(msg.data);
        $write("%c", char);
      end
      PrintIntLow: begin
        printIntLow <= msg.data;
      end
      PrintIntHigh: begin
        $display("%0d", {msg.data, printIntLow});
      end
    endcase
  endrule
endmodule
