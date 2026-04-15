import Fifo::*;

import Types::*;
import ProcTypes::*;
import SimInterfaces::*;
import SimConnectalWrapper::*;

`include "Autoconf.bsv"

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

`ifdef CONFIG_DIFFTEST
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
`endif
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
