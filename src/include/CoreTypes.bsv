import Types::*;
import ProcTypes::*;
import ICache::*;
import Tlb::*;
import AxiTypes::*;
`include "Autoconf.bsv"
`ifdef CONFIG_VSIM
`define CONFIG_WB_DEBUG
`define CONFIG_WB_DEBUG_INST
`endif
`ifdef CONFIG_FPGA
`define CONFIG_WB_DEBUG
`endif
`ifdef CONFIG_DIFFTEST
import DiffTypes::*;
`endif

interface Core;
  method Action setInterrupt(Bit#(8) val);
`ifdef CONFIG_BSIM
  method ActionValue#(CpuToHostData) cpuToHost;
  method Bool cpuToHostValid;
  method Action hostToCpu(Addr startpc);
`endif
`ifdef CONFIG_DIFFTEST
`ifdef CONFIG_BSIM
  method ActionValue#(DiffTrace) diffTrace;
  method Bool diffTraceValid;
`else
  (* always_ready *)
  method Bool diffStepValid;
  (* always_ready *)
  method Bit#(142) liveDiffCommitBundle;
  (* always_ready *)
  method Bit#(1024) liveDiffRegsBundle;
  (* always_ready *)
  method Bit#(832) liveDiffCsrBundle;
  (* always_ready *)
  method Bit#(130) liveDiffExcpBundle;
  (* always_ready *)
  method Bit#(200) liveDiffStoreBundle;
  (* always_ready *)
  method Bit#(136) liveDiffLoadBundle;
`endif
`endif
  interface AxiMemMaster axiMem;
`ifdef CONFIG_WB_DEBUG
  (* always_ready, always_enabled *)
  method Action debugInput(Bool breakPoint, Bool inforFlag, RIndx regNum);
  (* always_ready *)
  method Bool wsValid;
  (* always_ready *)
  method Data rfRdata;
  (* always_ready *)
  method Addr debug0WbPc;
  (* always_ready *)
  method Bit#(4) debug0WbRfWen;
  (* always_ready *)
  method RIndx debug0WbRfWnum;
  (* always_ready *)
  method Data debug0WbRfWdata;
`ifdef CONFIG_WB_DEBUG_INST
  (* always_ready *)
  method Instruction debug0WbInst;
`endif
`endif
endinterface

// IF1 -> IF2 packet: carries PC selection result and CSR context for translation
typedef struct {
  Addr             pc;
  Addr             predPc;
  Data             crmd;
  Data             asid;
  Data             dmw0;
  Data             dmw1;
  MmuTranslateType transType;
} F1toF2 deriving(Bits, Eq);

// IF2 -> ID packet (replaces old F2D)
typedef struct {
  Addr        pc;
  Addr        predPc;
  Instruction inst;
  Addr        instPaddr;
  ExcpInfo    excp;
}   F2D deriving(Bits, Eq);

typedef struct {
  Addr        pc;
  Addr        predPc;
  Instruction inst;
  DecodedInst dInst;
  ExcpInfo    excp;
}   D2RN deriving(Bits, Eq);

typedef struct {
  Bool      valid;
  Bit#(6)   ecode;
  Bit#(9)   esubcode;
  Addr      badv;
} ExcpInfo deriving(Bits, Eq);

typedef enum {
  Direct,
  Translate,
  None
} MmuTranslateType deriving(Bits, Eq);

typedef enum {
  Suc,
  Cc,
  Reserved,
  Reserved1
} MatType deriving(Bits, Eq);

typedef enum {
  MmuFetch,
  MmuLoad,
  MmuStore
} MmuAccessType deriving(Bits, Eq);

typedef struct {
  Addr    pa;
  MatType mat;
  Bool    fromDmw;
  Bool    fromTlb;
  Bool    excValid;
  Bit#(6) ecode;
  Bit#(9) esubcode;
  Addr    badv;
} MmuResult deriving(Bits, Eq);

Addr startpc = 32'h1c000000;

typedef struct {
  Bool      valid;
  Bit#(13) enabledVector;
  Bit#(4)  interruptNo;
} InterruptInfo deriving(Bits, Eq);

typedef enum {
  CommitIdle,
  CommitReady,
  CommitInterruptReady,
  CommitTLBWait
} CommitState deriving(Bits, Eq);
