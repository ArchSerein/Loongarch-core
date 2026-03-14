import Vector::*;
import Fifo::*;

import Types::*;
import ProcTypes::*;
import MemTypes::*;
import MemoryService::*;
import SimInterfaces::*;
import AxiMem::*;
import CoreAxiTop::*;

typedef 20 TbWordAddrSz;
typedef Bit#(TbWordAddrSz) TbWordAddr;
typedef 100000000 TbMaxCycles;

module mkTbCore#(SimIndication indication)(SimRequest);
  Reg#(Bool) started <- mkReg(False);
  Reg#(Bit#(16)) printIntLow <- mkReg(0);
  Reg#(Bit#(64)) cycles <- mkReg(0);

  Fifo#(32, Data) readRespQ <- mkCFFifo;

  MemoryService memSvc = interface MemoryService;
  method Action writeReq(Addr wordAddr, Data d, Bit#(8) mask);
    indication.write_mem_req(wordAddr, d,mask);
  endmethod

  method Action readReq(Addr wordAddr);
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
    PrintIntLow: begin
      printIntLow <= msg.data;
    end
    PrintIntHigh: begin
      $display("%0d", {msg.data, printIntLow});
    end
  endcase
endrule

`ifdef CONFIG_DIFFTEST
rule drainDiffCommit (started && core.diffCommitValid);
  let c <- core.diffCommit;
  indication.difftest_instr_commit(c.pc, c.inst, pack(c.wen), c.wdest, c.wdata);
endrule
`endif

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
  Fifo#(64, Bit#(32)) readMemReqQ <- mkCFFifo;
  Fifo#(64, Bit#(72)) writeMemReqQ <- mkCFFifo;

  SimIndication indicationSink = interface SimIndication;
  method Action halt(Bit#(32) code);
    haltQ.enq(code);
  endmethod

  method Action read_mem_req(Addr addr);
    readMemReqQ.enq(addr);
  endmethod

  method Action write_mem_req(Addr addr, Data data, Bit#(8) mask);
    writeMemReqQ.enq({addr, data, mask});
  endmethod

  method Action difftest_instr_commit(
      Bit#(32) pc,
      Instruction inst,
      Bit#(1) wen,
      Bit#(5) wdest,
      Data wdata);
    noAction;
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

  method ActionValue#(Bit#(32)) read_mem_req if (readMemReqQ.notEmpty);
    let addr = readMemReqQ.first;
    readMemReqQ.deq;
    return addr;
  endmethod

  method ActionValue#(Bit#(72)) write_mem_req if (writeMemReqQ.notEmpty);
    let req = writeMemReqQ.first;
    writeMemReqQ.deq;
    return req;
  endmethod
endinterface
endmodule
