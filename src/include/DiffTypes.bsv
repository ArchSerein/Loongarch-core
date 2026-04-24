import Types::*;
import Vector::*;
`include "Autoconf.bsv"

`ifdef CONFIG_DIFFTEST
typedef struct {
  Bool valid;
  Addr pc;
  Addr nextPc;
  Instruction inst;
  Bool wen;
  Bit#(5) wdest;
  Data wdata;
  Bool skip;  // Reserved for compatibility, currently hardwired to 0.
  Bool isTlbfill;
  Bit#(5) tlbfillIndex;
} DiffCommit deriving(Bits, Eq);

typedef struct {
  Vector#(32, Data) gpr;
} DiffArchGRegState deriving(Bits, Eq);

typedef struct {
  Data crmd;
  Data prmd;
  Data euen;
  Data ecfg;
  Data era;
  Data badv;
  Data eentry;
  Data tlbidx;
  Data tlbehi;
  Data tlbelo0;
  Data tlbelo1;
  Data asid;
  Data pgdl;
  Data pgdh;
  Data save0;
  Data save1;
  Data save2;
  Data save3;
  Data tid;
  Data tcfg;
  Data tval;
  Data llbctl;
  Data tlbrentry;
  Data dmw0;
  Data dmw1;
  Data estat;
} DiffArchCsrState deriving(Bits, Eq);

typedef struct {
  Bool excpValid;
  Bool eret;
  Data interrupt;
  Data exception;
  Addr exceptionPC;
  Instruction exceptionInst;
} DiffExcpEvent deriving(Bits, Eq);

typedef struct {
  Bit#(8) valid;
  Bit#(64) paddr;
  Bit#(64) vaddr;
  Bit#(64) data;
} DiffStoreEvent deriving(Bits, Eq);

typedef struct {
  Bit#(8) valid;
  Bit#(64) paddr;
  Bit#(64) vaddr;
} DiffLoadEvent deriving(Bits, Eq);

typedef struct {
  Bool isLoad;
  Bool isStore;
  Bool isSc;
  Addr paddr;
  Addr vaddr;
  Data storeData;
} DiffMemOp deriving(Bits, Eq);

typedef struct {
  DiffCommit commit;
  DiffArchGRegState regs;
  DiffArchCsrState csr;
  DiffExcpEvent excp;
  DiffStoreEvent store;
  DiffLoadEvent load;
} DiffTrace deriving(Bits, Eq);
`endif
