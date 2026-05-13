import Types::*;
import ProcTypes::*;
import Scoreboard::*;
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
`ifdef CONFIG_DIFFTEST
  Instruction inst;
`else
`ifdef CONFIG_WB_DEBUG_INST
  Instruction inst;
`endif
`endif
  DecodedInst dInst;
  ExcpInfo    excp;
}   D2R deriving(Bits, Eq);

typedef struct {
  Addr        pc;
  Addr        predPc;
`ifdef CONFIG_DIFFTEST
  Instruction inst;
`else
`ifdef CONFIG_WB_DEBUG_INST
  Instruction inst;
`endif
`endif
  Data        rVal1;
  Data        rVal2;
  Data        csrVal;
  Bool        isNeedFlush;
  ScoreboardTag sbTag;
  DecodedInst rInst;
  ExcpInfo    excp;
}   R2E deriving(Bits, Eq);

// EXE -> MEM packet: addr carries AGU result; memPaddr/memUseCache
// will be filled in by the MEM stage after D-MMU translation
typedef struct {
  Addr                pc;
`ifdef CONFIG_DIFFTEST
  Instruction         inst;
`else
`ifdef CONFIG_WB_DEBUG_INST
  Instruction         inst;
`endif
`endif
  ExcpInfo            excp;
  Maybe#(ByteMask)    mask;
  Bool                isNeedFlush;
  Bool                dataTlbLookupPending;
  ScoreboardTag       sbTag;
  Maybe#(ExecInst)    eInst;
}   E2M deriving(Bits, Eq);

// MEM -> WB packet: carries translated physical address from MEM stage
typedef struct {
  Addr                pc;
`ifdef CONFIG_DIFFTEST
  Instruction         inst;
  DiffArchCsrState    csrSnapshot;
`else
`ifdef CONFIG_WB_DEBUG_INST
  Instruction         inst;
`endif
`endif
  ExcpInfo            excp;
`ifdef CONFIG_DIFFTEST
  Maybe#(DiffMemOp)   diffMem;
`endif
  Addr                memPaddr;
  Bool                isNeedFlush;
  ScoreboardTag       sbTag;
  Maybe#(ExecInst)    mInst;
  Maybe#(TlbReadResult) tlbResult;
}   M2W deriving(Bits, Eq);

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

typedef struct {
  Bool    valid;
  Bool    stall;
  Bit#(5) index;
  Data    data;
} ForwardType deriving(Bits, Eq);


typedef enum {
  M2OpNone,
  M2OpDCache,
  M2OpICache,
  M2OpTlb
} Mem2Op deriving(Bits, Eq);

typedef struct {
  Addr                pc;
`ifdef CONFIG_DIFFTEST
  Instruction         inst;
`else
`ifdef CONFIG_WB_DEBUG_INST
  Instruction         inst;
`endif
`endif
  ExcpInfo            excp;
  Maybe#(ByteMask)    mask;
`ifdef CONFIG_DIFFTEST
  DiffArchCsrState    csrSnapshot;
`endif
  Bool                isNeedFlush;
  ScoreboardTag       sbTag;
  Maybe#(ExecInst)    eInst;
  Mem2Op              m2Op;
  Addr                memPaddr;
} M1toM2 deriving(Bits, Eq);

Addr startpc = 32'h1c000000;
