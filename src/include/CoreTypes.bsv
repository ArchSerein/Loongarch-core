import Types::*;
import ProcTypes::*;
import ICache::*;
import Tlb::*;
`include "Autoconf.bsv"
`ifdef CONFIG_DIFFTEST
import DiffTypes::*;
`endif

typedef 4 StoreBufEntries;

// IF1 -> IF2 packet: carries PC selection result and CSR context for translation
typedef struct {
  Addr             pc;
  Addr             predPc;
  Data             crmd;
  Data             asid;
  Data             dmw0;
  Data             dmw1;
  MmuTranslateType transType;
  ICacheProbeResp  probeRes;
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
`ifdef CONFIG_VSIM
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
`ifdef CONFIG_VSIM
  Instruction inst;
`endif
`endif
  Data        rVal1;
  Data        rVal2;
  Data        csrVal;
  Bool        isNeedFlush;
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
`ifdef CONFIG_VSIM
  Instruction         inst;
`endif
`endif
  ExcpInfo            excp;
  Maybe#(ByteMask)    mask;
  Bool                isNeedFlush;
  Bool                dataTlbLookupPending;
  Maybe#(ExecInst)    eInst;
}   E2M deriving(Bits, Eq);

// MEM -> WB packet: carries translated physical address from MEM stage
typedef struct {
  Addr                pc;
`ifdef CONFIG_DIFFTEST
  Instruction         inst;
  DiffArchCsrState    csrSnapshot;
`else
`ifdef CONFIG_VSIM
  Instruction         inst;
`endif
`endif
  ExcpInfo            excp;
`ifdef CONFIG_DIFFTEST
  Maybe#(DiffMemOp)   diffMem;
`endif
  Addr                memPaddr;
  Bool                isNeedFlush;
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
  M2OpTlb
} Mem2Op deriving(Bits, Eq);

typedef struct {
  Addr                pc;
`ifdef CONFIG_DIFFTEST
  Instruction         inst;
`else
`ifdef CONFIG_VSIM
  Instruction         inst;
`endif
`endif
  ExcpInfo            excp;
  Maybe#(ByteMask)    mask;
`ifdef CONFIG_DIFFTEST
  DiffArchCsrState    csrSnapshot;
`endif
  Bool                isNeedFlush;
  Maybe#(ExecInst)    eInst;
  Mem2Op              m2Op;
  Addr                memPaddr;
} M1toM2 deriving(Bits, Eq);

Addr startpc = 32'h1c000000;
