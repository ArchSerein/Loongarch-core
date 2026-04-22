import Types::*;
import Vector::*;
`include "Autoconf.bsv"

typedef enum {
  ExitCode = 2'd0,
  PrintChar = 2'd1,
  PrintIntLow = 2'd2,
  PrintIntHigh = 2'd3
} CpuToHostType deriving(Bits, Eq);

typedef struct {
  CpuToHostType c2hType;
  Bit#(16) data;
} CpuToHostData deriving(Bits, Eq, FShow);

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
} DiffCommit deriving(Bits, Eq, FShow);

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
  Bool valid;
  Bit#(64) paddr;
  Bit#(64) vaddr;
  Bit#(64) data;
} DiffStoreEvent deriving(Bits, Eq);

typedef struct {
  Bool valid;
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

typedef Bit#(5) RIndx;

typedef Bit#(6)  Op_31_26;
typedef Bit#(4)  Op_25_22;
typedef Bit#(2)  Op_21_20;
typedef Bit#(5)  Op_19_15;
typedef Bit#(2)  Op_25_24;

typedef Bit#(14) CsrIndx;

CsrIndx csrCpuid = 14'h020; // CPUID
CsrIndx csrMtohost = 14'h7a8; // simulation-only: cpu-to-host

Data scSucc = 1;
Data scFail = 0;

typedef enum {
  Unsupported,

  Alu,
  Lu12i, // LU12I.W
  Pcaddu12i, // PCADDU12I

  Ld,
  St,
  Ll, // LL.W
  Sc, // SC.W

  Br, // BEQ/BNE/BLT/BGE/BLTU/BGEU
  J, // B / BL
  Jr, // JIRL

  Csrr, // CSRRD
  Csrw, // CSRWR
  Csrxchg, // CSRXCHG
  RdTimeL, // RDTIMEL.W rd, r0
  RdTimeH, // RDTIMEH.W rd, r0
  RdCntId, // RDTIMEL.W r0, rj (Counter ID writeback only)

  Cacop, // CACOP
  Dbar, // DBAR
  Ibar, // IBAR

  Tlbsrch, // TLBSRCH
  Tlbrd, // TLBRD
  Tlbwr, // TLBWR
  Tlbfill, // TLBFILL
  Invtlb, // INVTLB

  Syscall, // SYSCALL exception
  Ertn, // ERTN return from exception
  Break // debug
} IType deriving(Bits, Eq);

typedef enum {
  Eq,
  Neq,
  Lt,
  Ltu,
  Ge,
  Geu,
  AT,
  NT
} BrFunc deriving(Bits, Eq);

typedef enum {
  AddW,
  SubW,
  Nor_,
  And_,
  Or_,
  Xor_,
  Slt,
  Sltu,
  SllW,
  SrlW,
  SraW
} AluFunc deriving(Bits, Eq);

typedef enum {
  MulW,
  MulhW,
  MulhWu,
  DivW,
  DivWu,
  ModW,
  ModWu
} MulDivFunc deriving(Bits, Eq);

typedef void Exception;

typedef struct {
  Addr pc;
  Addr nextPc;
  IType brType;
  Bool taken;
  Bool mispredict;
} Redirect deriving(Bits, Eq);

typedef struct {
  IType               iType;
  Maybe#(AluFunc)     aluFunc;
  Maybe#(MulDivFunc)  muldivFunc;
  BrFunc              brFunc;
  Maybe#(RIndx)       dst;
  Maybe#(RIndx)       src1;
  Maybe#(RIndx)       src2;
  Maybe#(CsrIndx)     csr;
  Maybe#(Data)        imm;
  Maybe#(Bit#(5))     cacheOp;
  Maybe#(ByteMask)    mask;
} DecodedInst deriving(Bits, Eq);

typedef struct {
  IType            iType;
  Maybe#(RIndx)    dst;
  Maybe#(CsrIndx)  csr;
  Maybe#(Data)     imm;
  Maybe#(Bit#(5))  cacheOp;
  Data             data;
  Maybe#(ByteMask) mask;
  Addr             addr;
  Bool             mispredict;
  Bool             brTaken;
} ExecInst deriving(Bits, Eq);

function Bool dataHazard(Maybe#(RIndx) src1, Maybe#(RIndx) src2, Maybe#(RIndx)
  dst);
  return(isValid(dst) && ((isValid(src1) && fromMaybe(?, dst) == fromMaybe(?,
    src1)) ||
    (isValid(src2) && fromMaybe(?, dst) == fromMaybe(?, src2))));
endfunction
