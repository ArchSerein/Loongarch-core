package SimConnectalWrapper;

export SimInterfaces::*;
export mkTbCore;
export mkSimConnectalWrapper;

import Fifo::*;

import Types::*;
import ProcTypes::*;
import MemTypes::*;
import MemoryService::*;
import SimInterfaces::*;
import AxiMem::*;
import Core::*;

`include "Autoconf.bsv"

typedef 100000000 TbMaxCycles;

module mkTbCore#(SimIndication indication)(SimRequest);
  Reg#(Bool) started <- mkReg(True);
  Reg#(Bit#(16)) printIntLow <- mkRegU;
  Reg#(Bit#(64)) cycles <- mkReg(0);

  Fifo#(32, Data) readRespQ <- mkCFFifo;

  MemoryService memSvc = interface MemoryService;
    method Action writeReq(Addr wordAddr, Data d, Bit#(8) mask);
      indication.write_mem_req(wordAddr, d, mask);
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

  Core core <- mkCore;
  Empty _axiMemSim <- mkAxiMemSimBridge(core.axiMem, memSvc);

  rule countCycles(started && cycles != fromInteger(valueOf(TbMaxCycles) - 1));
    cycles <= cycles + 1;
  endrule

  rule forceHalt(started && cycles == fromInteger(valueOf(TbMaxCycles) - 1));
    indication.halt(32'h00000002);
    started <= False;
  endrule

  rule drainCpuToHost(core.cpuToHostValid);
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
  rule drainDiffTrace(started && core.diffTraceValid);
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
      pack(t.commit.skip),
      pack(t.commit.isTlbfill),
      t.commit.tlbfillIndex
    );
  endrule
`endif

  method Action hostToCpu(Bit#(32) startpc);
    started <= True;
    cycles <= 0;
    core.hostToCpu(zeroExtend(startpc));
  endmethod

  method Action read_mem_resp(Data data);
    readRespQ.enq(data);
  endmethod
endmodule

module mkSimConnectalWrapper#(SimIndication indication)(SimConnectalWrapper);
  SimRequest coreReq <- mkTbCore(indication);
  interface request = coreReq;
endmodule

endpackage
