import Types::*;
`include "Autoconf.bsv"

// Hardware -> software callback interface (Connectal indication).
interface SimIndication;
  method Action halt(Bit#(32) code);
  method Action read_mem_req(Addr addr);
  method Action write_mem_req(Addr addr, Data data, Bit#(8) mask);
`ifdef CONFIG_DIFFTEST
  method Action difftest_greg_state(
    Data gpr_0, Data gpr_1, Data gpr_2, Data gpr_3,
    Data gpr_4, Data gpr_5, Data gpr_6, Data gpr_7,
    Data gpr_8, Data gpr_9, Data gpr_10, Data gpr_11,
    Data gpr_12, Data gpr_13, Data gpr_14, Data gpr_15,
    Data gpr_16, Data gpr_17, Data gpr_18, Data gpr_19,
    Data gpr_20, Data gpr_21, Data gpr_22, Data gpr_23,
    Data gpr_24, Data gpr_25, Data gpr_26, Data gpr_27,
    Data gpr_28, Data gpr_29, Data gpr_30, Data gpr_31
  );
  method Action difftest_csr_state(
    Data crmd, Data prmd, Data euen, Data ecfg,
    Data estat, Data era, Data badv, Data eentry,
    Data tlbidx, Data tlbehi, Data tlbelo0, Data tlbelo1,
    Data asid, Data pgdl, Data pgdh,
    Data save0, Data save1, Data save2, Data save3,
    Data tid, Data tcfg, Data tval, Data llbctl,
    Data tlbrentry, Data dmw0, Data dmw1
  );
  method Action difftest_excp_event(
    Bit#(1) excp_valid,
    Bit#(1) eret,
    Bit#(32) intrNo,
    Bit#(32) cause,
    Bit#(32) exceptionPC,
    Bit#(32) exceptionInst
  );
  method Action difftest_store_event(
    Bit#(1) valid,
    Bit#(64) storePAddr,
    Bit#(64) storeVAddr,
    Bit#(64) storeData
  );
  method Action difftest_load_event(
    Bit#(1) valid,
    Bit#(64) paddr,
    Bit#(64) vaddr
  );
  method Action difftest_instr_commit(
    Bit#(1) valid,
    Bit#(32) pc,
    Bit#(32) nextPc,
    Instruction inst,
    Bit#(1) wen,
    Bit#(5) wdest,
    Data wdata,
    Bit#(1) skip
  );
`endif
endinterface

// Host -> hardware request interface (Connectal request).
interface SimRequest;
  method Action hostToCpu(Bit#(32) startpc);
  method Action read_mem_resp(Data data);
endinterface

// Connectal build top-level wrapper.
interface SimConnectalWrapper;
  interface SimRequest request;
endinterface

// Verilator-side polling interface for indications.
interface SimPollIndication;
  method ActionValue#(Bit#(32)) halt();
  method ActionValue#(Bit#(32)) read_mem_req();
  method ActionValue#(Bit#(72)) write_mem_req();
endinterface

interface SimTop;
  interface SimRequest request;
  interface SimPollIndication indication;
endinterface
