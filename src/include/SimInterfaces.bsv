import Types::*;

// Hardware -> software callback interface (Connectal indication).
interface SimIndication;
  method Action halt(Bit#(32) code);
  method Action putc(Bit#(8) c);
  method Action read_mem_req(Addr addr);
  method Action write_mem_req(Addr addr, Data data, Bit#(8) mask);
  method Action difftest_instr_commit(
    Bit#(32) pc,
    Instruction inst,
    Bit#(1) wen,
    Bit#(5) wdest,
    Data wdata
  );
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
  method ActionValue#(Bit#(8)) putc();
  method ActionValue#(Bit#(32)) read_mem_req();
  method ActionValue#(Bit#(72)) write_mem_req();
endinterface

interface SimTop;
  interface SimRequest request;
  interface SimPollIndication indication;
endinterface
