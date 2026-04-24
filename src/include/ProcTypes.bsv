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
} CpuToHostData deriving(Bits, Eq);

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
