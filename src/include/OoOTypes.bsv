import Types::*;
import ProcTypes::*;
import CoreTypes::*;
import Vector::*;

// ============================================================
// OoO Processor Type Definitions
// Based on docs/ooo_processor_design.md (Tomasulo + PRF + ROB)
// ============================================================

// Physical register index: 64 physical registers (32 arch + 32 speculative)
typedef Bit#(6) PIndx;

// ROB tag: 32-entry reorder buffer
typedef Bit#(5) RobTag;

// Speculative epoch: incremented on ROB recovery so reused ROB slots do not
// match stale asynchronous responses.
typedef Bit#(4) SpecEpoch;

typedef struct {
  RobTag    index;
  SpecEpoch epoch;
} RobToken deriving(Bits, Eq);

typedef enum {
  StoreSpeculative,
  StoreCommitted,
  StoreIssued
} StoreState deriving(Bits, Eq);

// ROB entry state
typedef enum {
  RobIssued,
  RobExecuting,
  RobCompleted
} RobState deriving(Bits, Eq);

// Common Data Bus message: broadcast by completing FUs
typedef struct {
  PIndx  tag;    // completed physical register number
  Data   value;  // result data
  Bool   valid;  // valid this cycle
} CDBMessage deriving(Bits, Eq);

// Reorder Buffer entry
typedef struct {
  Bool             valid;
  RobToken         token;
  RobState         state;
  Addr             pc;
  Instruction      inst;
  Maybe#(PIndx)    pDst;         // destination physical register
  Maybe#(PIndx)    oldPdst;      // old physical register (for free list release)
  Maybe#(RIndx)    dst;          // logical destination register (for commit)
  PIndx            pSrc1;        // source 1 physical register (for CSR/TLB commit)
  PIndx            pSrc2;        // source 2 physical register (for CSR/TLB commit)
  IType            iType;        // instruction type (determines commit behavior)
  ExcpInfo         excp;         // exception info
  Bool             isBranch;     // branch flag
  Bool             isStore;      // store flag
  Bool             isCsr;        // CSR flag
  Bool             isTlb;        // TLB flag
  Bool             isSpecial;    // Ertn/Idle/Syscall/Break
  Bool             mispredict;   // branch mispredict flag
  Addr             correctTarget; // correct branch target
  Addr             memVaddr;     // virtual address (for memory ops, Difftest)
  Addr             memPaddr;     // physical address (for memory ops, Difftest)
  Bool             memUseCache;  // whether memory op should use D-Cache
  Maybe#(ByteMask) memMask;      // original access size/sign mask for Difftest
} RobEntry deriving(Bits, Eq);

// ROB physical storage groups.  RobEntry remains the compatibility head/enq view.
typedef struct {
  RobToken      token;
  Addr          pc;
  Instruction   inst;
  Maybe#(PIndx) pDst;
  Maybe#(PIndx) oldPdst;
  Maybe#(RIndx) dst;
  PIndx         pSrc1;
  PIndx         pSrc2;
  IType         iType;
  Bool          isBranch;
  Bool          isStore;
  Bool          isCsr;
  Bool          isTlb;
  Bool          isSpecial;
} RobStaticEntry deriving(Bits, Eq);

typedef struct {
  RobState state;
  ExcpInfo excp;
  Bool     mispredict;
  Addr     correctTarget;
} RobExecStatus deriving(Bits, Eq);

typedef struct {
  Addr             vaddr;
  Addr             paddr;
  Bool             useCache;
  Maybe#(ByteMask) mask;
} RobMemInfo deriving(Bits, Eq);

// Narrow ROB head views used by commit/issue without assembling a full entry.
typedef struct {
  RobToken token;
  RobState state;
  IType    iType;
  ExcpInfo excp;
  Bool     isBranch;
  Bool     isStore;
  Bool     isCsr;
  Bool     isTlb;
  Bool     isSpecial;
  Bool     mispredict;
  Addr     correctTarget;
} RobHeadStatus deriving(Bits, Eq);

typedef struct {
  Addr          pc;
  Instruction   inst;
  Maybe#(PIndx) pDst;
  Maybe#(PIndx) oldPdst;
  Maybe#(RIndx) dst;
  PIndx         pSrc1;
  PIndx         pSrc2;
} RobHeadCommitMeta deriving(Bits, Eq);

// Reservation Station operand state shared by FU-specific RS entries.
typedef struct {
  Maybe#(PIndx) qj;  // source 1 dependency (Invalid = ready)
  Maybe#(PIndx) qk;  // source 2 dependency (Invalid = ready)
  Data          vj;  // source 1 value
  Data          vk;  // source 2 value
} RSOperandState deriving(Bits, Eq);

// ALU reservation station entry: ALU, cpucfg and branch metadata only.
typedef struct {
  IType           iType;
  Maybe#(AluFunc) aluFunc;
  BrFunc          brFunc;
  Maybe#(PIndx)   pDst;
  RobTag          robTag;
  RobToken        token;
  Maybe#(Data)    imm;
  Addr            pc;
  Addr            predPc;
} AluRSPayload deriving(Bits, Eq);

typedef struct {
  AluRSPayload  payload;
  RSOperandState operands;
} AluIssueEntry deriving(Bits, Eq);

// MulDiv reservation station entry: no branch, memory or ALU-only metadata.
typedef struct {
  IType              iType;
  Maybe#(MulDivFunc) muldivFunc;
  Maybe#(PIndx)      pDst;
  RobTag             robTag;
  RobToken           token;
} MulDivRSPayload deriving(Bits, Eq);

typedef struct {
  MulDivRSPayload payload;
  RSOperandState  operands;
} MulDivIssueEntry deriving(Bits, Eq);

// Memory reservation station entry: address-generation and memory side-effect metadata.
typedef struct {
  IType             iType;
  Maybe#(PIndx)     pDst;
  RobTag            robTag;
  RobToken          token;
  Maybe#(Data)      imm;
  Maybe#(ByteMask)  mask;
  Maybe#(Bit#(5))   cacheOp;
  Bool              isStore;
  Bool              isLoad;
} MemRSPayload deriving(Bits, Eq);

typedef struct {
  MemRSPayload  payload;
  RSOperandState operands;
} MemIssueEntry deriving(Bits, Eq);

// Renamed instruction (RN stage output)
typedef struct {
  Addr           pc;
  Addr           predPc;
  Instruction    inst;
  DecodedInst    dInst;
  PIndx          pSrc1;     // source 1 physical register
  PIndx          pSrc2;     // source 2 physical register
  PIndx          pDst;      // destination physical register
  PIndx          oldPdst;   // old destination (for ROB release)
  RobTag         robTag;    // ROB tag
  RobToken       token;     // ROB slot + speculative epoch
  Bool           isBranch;  // branch flag (needs checkpoint)
  ExcpInfo       excp;      // exception info
} RenamedInst deriving(Bits, Eq);

// Store Buffer entry (for SQ)
typedef struct {
  RobToken  owner;
  StoreState state;
  Addr      vaddr;
  Addr      paddr;
  Bool      useCache;
  Data      data;
  ByteMask  byteEn;
} StoreBufEntry deriving(Bits, Eq);

// Store forwarding result (for Load-to-Store forwarding)
typedef struct {
  Data      data;
  ByteMask  byteEn;
} StoreForwardResult deriving(Bits, Eq);

// Load Queue entry
typedef struct {
  Bool           valid;       // entry occupied
  RobTag         robTag;
  Addr           vaddr;       // virtual address
  Maybe#(Addr)   paddr;       // physical address (after TLB)
  Bool           done;        // load completed
  Bool           replay;     // needs replay (mispeculation)
} LQEntry deriving(Bits, Eq);

// ============================================================
// Instruction classification helpers
// ============================================================

function Bool isBranch(IType t);
  return t == Br || t == J || t == Jr;
endfunction

function Bool isStore(IType t);
  return t == St || t == Sc;
endfunction

function Bool isLoad(IType t);
  return t == Ld || t == Ll;
endfunction

function Bool isMulDiv(Maybe#(MulDivFunc) mf);
  return isValid(mf);
endfunction

function Bool isCsr(IType t);
  return t == Csrr || t == Csrw || t == Csrxchg ||
         t == RdTimeL || t == RdTimeH || t == RdCntId;
endfunction

function Bool isTlb(IType t);
  return t == Tlbsrch || t == Tlbrd || t == Tlbwr ||
         t == Tlbfill || t == Invtlb;
endfunction

function Bool isSpecial(IType t);
  return t == Ertn || t == Idle || t == Syscall || t == Break;
endfunction

function Bool isMem(IType t);
  return t == Ld || t == St || t == Ll || t == Sc ||
         t == Cacop || t == Dbar || t == Ibar;
endfunction

function Bool sameRobToken(RobToken a, RobToken b);
  return a.index == b.index && a.epoch == b.epoch;
endfunction

function Bool robTokenYoungerThan(RobToken token, RobToken base, RobTag headTag);
  Bit#(5) tokenAge = token.index - headTag;
  Bit#(5) baseAge = base.index - headTag;
  return token.epoch == base.epoch && tokenAge > baseAge;
endfunction

function Bool robTokenOlderThan(RobToken token, RobToken base, RobTag headTag);
  Bit#(5) tokenAge = token.index - headTag;
  Bit#(5) baseAge = base.index - headTag;
  return token.epoch != base.epoch || tokenAge < baseAge;
endfunction

function Bool isAlu(IType t);
  return t == Alu || t == Lu12i || t == Pcaddu12i || t == Cpucfg;
endfunction

function Bool isCsrTlbSpecial(IType t);
  return isCsr(t) || isTlb(t) || isSpecial(t);
endfunction

// Memory execution state machine (for in-order memory ops)
typedef enum {
  MemIdle,        // no memory operation in flight
  MemTLBWait,     // waiting for TLB data lookup response
  MemCacheWait,   // waiting for D-Cache response
  MemUncacheWait, // translated MMIO load waiting to reach ROB head
  MemCacopIWait,  // waiting for I-Cache cacop response
  MemIbarWait,    // waiting for full I-Cache invalidation
  MemTLBOpWait,   // waiting for TLB operation response (Tlbrd/Tlbwr/etc.)
  MemExcpWait     // latched memory alignment exception to report
} MemExecState deriving(Bits, Eq);

// Normalize a logical register index for renaming: R0 is never renamed
function Maybe#(RIndx) normalizeReg(Maybe#(RIndx) r);
  if (r matches tagged Valid .rv &&& rv == 0) begin
    return tagged Invalid;
  end else begin
    return r;
  end
endfunction


function LQEntry invalidLQEntry();
  return LQEntry {
    valid: False, robTag: ?, vaddr: ?, paddr: ?, done: ?, replay: ?
  };
endfunction
