import Vector::*;
import Fifo::*;

import Types::*;
import ProcTypes::*;
import MemTypes::*;
import CacheTypes::*;
import Core::*;
import MemoryService::*;
import SimInterfaces::*;

typedef 20 TbWordAddrSz;
typedef Bit#(TbWordAddrSz) TbWordAddr;
typedef 1000000 TbMaxCycles;

typedef enum {
  WideMemIdle,
  WideMemSendReadReq,
  WideMemWaitReadResp,
  WideMemSendWriteReq
} TbWideMemState deriving(Bits, Eq);

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

module mkTbCore#(SimIndication indication)(SimRequest);
  Reg#(Bool) started <- mkReg(False);
  Reg#(Bit#(16)) printIntLow <- mkReg(0);
  Reg#(Bit#(64)) cycles <- mkReg(0);

  Fifo#(32, Data) readRespQ <- mkCFFifo;

  MemoryService memSvc = interface MemoryService;
    method Action writeReq(Bit#(32) wordAddr, Data d);
      if (!inTbMemRange32(wordAddr)) begin
        $fwrite(stderr, "TB: write word address out of range: %08x\n", wordAddr);
        indication.halt(32'h00000001);
      end
      else begin
        indication.write_mem_req(wordAddr, d);
      end
    endmethod

    method Action readReq(Bit#(32) wordAddr);
      if (!inTbMemRange32(wordAddr)) begin
        $fwrite(stderr, "TB: read word address out of range: %08x\n", wordAddr);
        indication.halt(32'h00000001);
      end
      else begin
        indication.read_mem_req(wordAddr);
      end
    endmethod

    method Bool readRespValid = readRespQ.notEmpty;

    method ActionValue#(Data) readResp if (readRespQ.notEmpty);
      let d = readRespQ.first;
      readRespQ.deq;
      return d;
    endmethod
  endinterface;

  WideMem wideMemWrapper <- mkTbWideMem(memSvc);
  Core core <- mkCore(wideMemWrapper);

  rule countCycles (started);
    cycles <= cycles + 1;
    if (cycles == fromInteger(valueOf(TbMaxCycles) - 1)) begin
      indication.halt(32'h00000002);
      started <= False;
    end
  endrule

  rule drainCpuToHost (started && core.cpuToHostValid);
    let msg <- core.cpuToHost;
    case (msg.c2hType)
      ExitCode: begin
        indication.halt(zeroExtend(msg.data));
        started <= False;
      end
      PrintChar: begin
        indication.putc(truncate(msg.data));
      end
      PrintIntLow: begin
        printIntLow <= msg.data;
      end
      PrintIntHigh: begin
        $display("%0d", {msg.data, printIntLow});
      end
    endcase
  endrule

  method Action hostToCpu(Bit#(32) startpc) if (!started);
    started <= True;
    cycles <= 0;
    core.hostToCpu(zeroExtend(startpc));
  endmethod

  method Action read_mem_resp(Data data);
    readRespQ.enq(data);
  endmethod
endmodule

(* synthesize *)
module mkSimConnectalWrapper#(SimIndication indication)(SimConnectalWrapper);
  SimRequest coreReq <- mkTbCore(indication);
  interface request = coreReq;
endmodule

(* synthesize *)
module mkTb(SimTop);
  Fifo#(8, Bit#(32)) haltQ <- mkCFFifo;
  Fifo#(32, Bit#(8)) putcQ <- mkCFFifo;
  Fifo#(64, Bit#(32)) readMemReqQ <- mkCFFifo;
  Fifo#(64, Bit#(64)) writeMemReqQ <- mkCFFifo;

  SimIndication indicationSink = interface SimIndication;
    method Action halt(Bit#(32) code);
      haltQ.enq(code);
    endmethod

    method Action putc(Bit#(8) c);
      putcQ.enq(c);
    endmethod

    method Action read_mem_req(Bit#(32) addr);
      readMemReqQ.enq(addr);
    endmethod

    method Action write_mem_req(Bit#(32) addr, Data data);
      writeMemReqQ.enq({addr, data});
    endmethod
  endinterface;

  SimRequest coreReq <- mkTbCore(indicationSink);

  interface request = coreReq;

  interface SimPollIndication indication;
    method ActionValue#(Bit#(32)) halt if (haltQ.notEmpty);
      let code = haltQ.first;
      haltQ.deq;
      return code;
    endmethod

    method ActionValue#(Bit#(8)) putc if (putcQ.notEmpty);
      let c = putcQ.first;
      putcQ.deq;
      return c;
    endmethod

    method ActionValue#(Bit#(32)) read_mem_req if (readMemReqQ.notEmpty);
      let addr = readMemReqQ.first;
      readMemReqQ.deq;
      return addr;
    endmethod

    method ActionValue#(Bit#(64)) write_mem_req if (writeMemReqQ.notEmpty);
      let req = writeMemReqQ.first;
      writeMemReqQ.deq;
      return req;
    endmethod
  endinterface
endmodule
