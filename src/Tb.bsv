import Vector::*;
import Fifo::*;

import Types::*;
import ProcTypes::*;
import MemTypes::*;
import MemoryService::*;
import SimInterfaces::*;
import AxiMem::*;
import CoreAxiTop::*;

`include "Autoconf.bsv"

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

rule countCycles (started && cycles != fromInteger(valueOf(TbMaxCycles) - 1));
  cycles <= cycles + 1;
endrule

rule forceHalt (started && cycles == fromInteger(valueOf(TbMaxCycles) - 1));
  indication.halt(32'h00000002);
  started <= False;
endrule

rule drainCpuToHost (core.cpuToHostValid);
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

`IFDEF_DIFFTEST(
rule drainDiffTrace (started && core.diffTraceValid);
  let t <- core.diffTrace;
  indication.difftest_greg_state(
    t.regs.gpr[0], t.regs.gpr[1], t.regs.gpr[2], t.regs.gpr[3],
    t.regs.gpr[4], t.regs.gpr[5], t.regs.gpr[6], t.regs.gpr[7],
    t.regs.gpr[8], t.regs.gpr[9], t.regs.gpr[10], t.regs.gpr[11],
    t.regs.gpr[12], t.regs.gpr[13], t.regs.gpr[14], t.regs.gpr[15],
    t.regs.gpr[16], t.regs.gpr[17], t.regs.gpr[18], t.regs.gpr[19],
    t.regs.gpr[20], t.regs.gpr[21], t.regs.gpr[22], t.regs.gpr[23],
    t.regs.gpr[24], t.regs.gpr[25], t.regs.gpr[26], t.regs.gpr[27],
    t.regs.gpr[28], t.regs.gpr[29], t.regs.gpr[30], t.regs.gpr[31]
  );
  indication.difftest_csr_state(
    t.csr.crmd, t.csr.prmd, t.csr.euen, t.csr.ecfg,
    t.csr.estat, t.csr.era, t.csr.badv, t.csr.eentry,
    t.csr.tlbidx, t.csr.tlbehi, t.csr.tlbelo0, t.csr.tlbelo1,
    t.csr.asid, t.csr.pgdl, t.csr.pgdh,
    t.csr.save0, t.csr.save1, t.csr.save2, t.csr.save3,
    t.csr.tid, t.csr.tcfg, t.csr.tval, t.csr.llbctl,
    t.csr.tlbrentry, t.csr.dmw0, t.csr.dmw1
  );
  indication.difftest_excp_event(
    pack(t.excp.excpValid),
    pack(t.excp.eret),
    t.excp.interrupt,
    t.excp.exception,
    t.excp.exceptionPC,
    t.excp.exceptionInst
  );
  indication.difftest_store_event(
    pack(t.store.valid),
    t.store.paddr,
    t.store.vaddr,
    t.store.data
  );
  indication.difftest_load_event(
    pack(t.load.valid),
    t.load.paddr,
    t.load.vaddr
  );
  indication.difftest_instr_commit(
    pack(t.commit.valid),
    t.commit.pc,
    t.commit.nextPc,
    t.commit.inst,
    pack(t.commit.wen),
    t.commit.wdest,
    t.commit.wdata,
    pack(t.commit.skip)
  );
endrule
)

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

  `IFDEF_DIFFTEST(
  method Action difftest_greg_state(
      Data gpr_0, Data gpr_1, Data gpr_2, Data gpr_3,
      Data gpr_4, Data gpr_5, Data gpr_6, Data gpr_7,
      Data gpr_8, Data gpr_9, Data gpr_10, Data gpr_11,
      Data gpr_12, Data gpr_13, Data gpr_14, Data gpr_15,
      Data gpr_16, Data gpr_17, Data gpr_18, Data gpr_19,
      Data gpr_20, Data gpr_21, Data gpr_22, Data gpr_23,
      Data gpr_24, Data gpr_25, Data gpr_26, Data gpr_27,
      Data gpr_28, Data gpr_29, Data gpr_30, Data gpr_31);
    noAction;
  endmethod

  method Action difftest_csr_state(
      Data crmd, Data prmd, Data euen, Data ecfg,
      Data estat, Data era, Data badv, Data eentry,
      Data tlbidx, Data tlbehi, Data tlbelo0, Data tlbelo1,
      Data asid, Data pgdl, Data pgdh,
      Data save0, Data save1, Data save2, Data save3,
      Data tid, Data tcfg, Data tval, Data llbctl,
      Data tlbrentry, Data dmw0, Data dmw1);
    noAction;
  endmethod

  method Action difftest_excp_event(
      Bit#(1) excp_valid,
      Bit#(1) eret,
      Bit#(32) intrNo,
      Bit#(32) cause,
      Bit#(32) exceptionPC,
      Bit#(32) exceptionInst);
    noAction;
  endmethod

  method Action difftest_store_event(
      Bit#(1) valid,
      Bit#(64) storePAddr,
      Bit#(64) storeVAddr,
      Bit#(64) storeData);
    noAction;
  endmethod

  method Action difftest_load_event(
      Bit#(1) valid,
      Bit#(64) paddr,
      Bit#(64) vaddr);
    noAction;
  endmethod

  method Action difftest_instr_commit(
      Bit#(1) valid,
      Bit#(32) pc,
      Bit#(32) nextPc,
      Instruction inst,
      Bit#(1) wen,
      Bit#(5) wdest,
      Data wdata,
      Bit#(1) skip);
    noAction;
  endmethod
  )
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
