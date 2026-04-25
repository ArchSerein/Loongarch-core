import Types::*;
import ProcTypes::*;
`include "Autoconf.bsv"
`ifdef CONFIG_DIFFTEST
import DiffTypes::*;
`endif

typedef 4 StoreBufEntries;

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
  Addr                memPaddr;
  Bool                memUseCache;
  Bool                isNeedFlush;
  Maybe#(ExecInst)    eInst;
}   E2M deriving(Bits, Eq);

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
`ifdef CONFIG_DIFFTEST
  Maybe#(DiffMemOp)   diffMem;
`endif
  Addr                memPaddr;
  Bool                isNeedFlush;
  Maybe#(ExecInst)    mInst;
}   M2W deriving(Bits, Eq);

typedef struct {
  Bool      valid;
  Bit#(6)   ecode;
  Bit#(9)   esubcode;
  Addr      badv;
} ExcpInfo deriving(Bits, Eq);

typedef enum {
  FTransIdle,
  FTransProbe,
  FTransWaitRefill,
  FTransDone
} FetchTransState deriving(Bits, Eq);

typedef enum {
  Direct,
  Translate,
  None
} MmuTranslateType deriving(Bits, Eq);

typedef enum {
  Cc,
  Suc,
  Reserved,
  Reserved1
} MatType deriving(Bits, Eq);

typedef struct {
  Addr             pc;
  Addr             predPc;
  Data             crmd;
  Data             asid;
  Data             dmw0;
  Data             dmw1;
  MmuTranslateType transType;
  Bit#(4)          reqId;
} FetchTransReq deriving(Bits, Eq);

typedef struct {
  Addr     pc;
  Addr     predPc;
  Addr     instPaddr;
  Bit#(4)  reqId;
} FetchMissCtx deriving(Bits, Eq);

typedef struct {
  Instruction inst;
  Addr        instPaddr;
  ExcpInfo    excp;
} FetchResult deriving(Bits, Eq);

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
