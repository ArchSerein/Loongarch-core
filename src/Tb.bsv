import Vector::*;
import Fifo::*;

import Types::*;
import ProcTypes::*;
import MemTypes::*;
import CacheTypes::*;
import Core::*;
import MemoryService::*;
import SimInterfaces::*;
import AxiMem::*;
import CoreAxiTop::*;

typedef 20 TbWordAddrSz;
typedef Bit#(TbWordAddrSz) TbWordAddr;
typedef 1000000 TbMaxCycles;

module mkTbCore#(SimIndication indication)(SimRequest);
  Reg#(Bool) started <- mkReg(False);
  Reg#(Bit#(16)) printIntLow <- mkReg(0);
  Reg#(Bit#(64)) cycles <- mkReg(0);

  Fifo#(32, Data) readRespQ <- mkCFFifo;

  MemoryService memSvc = interface MemoryService;
  method Action writeReq(Bit#(32) wordAddr, Data d);
    indication.write_mem_req(wordAddr, d);
  endmethod

  method Action readReq(Bit#(32) wordAddr);
    indication.read_mem_req(wordAddr);
  endmethod

  method Bool readRespValid = readRespQ.notEmpty;

  method ActionValue#(Data) readResp if (readRespQ.notEmpty);
    let d = readRespQ.first;
    readRespQ.deq;
    return d;
  endmethod
endinterface;

CoreAxiTop core <- mkCoreAxiTop;
Empty _axiMemSim <- mkAxiMemSimBridge(core.axiMem, memSvc);

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
