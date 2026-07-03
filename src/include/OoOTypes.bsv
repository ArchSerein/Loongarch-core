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
  RobState         state;
  Addr             pc;
  Instruction      inst;
  Maybe#(PIndx)    pDst;         // destination physical register
  Maybe#(PIndx)    oldPdst;      // old physical register (for free list release)
  IType            iType;        // instruction type (determines commit behavior)
  ExcpInfo         excp;         // exception info
  Bool             isBranch;     // branch flag
  Bool             isStore;      // store flag
  Bool             isCsr;        // CSR flag
  Bool             isTlb;        // TLB flag
  Bool             isSpecial;    // Ertn/Idle/Syscall/Break
  Bool             mispredict;   // branch mispredict flag
  Addr             correctTarget; // correct branch target
} RobEntry deriving(Bits, Eq);

// Reservation Station entry (used for ALU, MulDiv, and Memory RS)
typedef struct {
  Bool                valid;
  IType               iType;
  Maybe#(AluFunc)     aluFunc;
  Maybe#(MulDivFunc)  muldivFunc;
  BrFunc              brFunc;
  Maybe#(PIndx)       qj;       // source 1 dependency (Invalid = ready)
  Maybe#(PIndx)       qk;       // source 2 dependency (Invalid = ready)
  Data                vj;       // source 1 value
  Data                vk;       // source 2 value
  Maybe#(PIndx)       pDst;     // destination physical register
  RobTag              robTag;   // ROB tag
  Maybe#(Data)        imm;      // immediate
  Addr                pc;       // program counter
  Addr                predPc;   // predicted PC (for branch)
  Maybe#(ByteMask)    mask;     // byte mask (for memory ops)
  Bool                isStore;  // store flag
  Bool                isLoad;   // load flag
} RSEntry deriving(Bits, Eq);

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
  Bool           isBranch;  // branch flag (needs checkpoint)
  ExcpInfo       excp;      // exception info
} RenamedInst deriving(Bits, Eq);

// Store Buffer entry (for SQ)
typedef struct {
  Addr      addr;
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

function Bool isAlu(IType t);
  return t == Alu || t == Lu12i || t == Pcaddu12i;
endfunction

// Normalize a logical register index for renaming: R0 is never renamed
function Maybe#(RIndx) normalizeReg(Maybe#(RIndx) r);
  if (r matches tagged Valid .rv &&& rv == 0) begin
    return tagged Invalid;
  end else begin
    return r;
  end
endfunction

// Invalid entry constructors (for invalidation without 'with' syntax)
function RSEntry invalidRSEntry();
  return RSEntry {
    valid: False, iType: ?, aluFunc: ?, muldivFunc: ?, brFunc: ?,
    qj: ?, qk: ?, vj: ?, vk: ?, pDst: ?, robTag: ?,
    imm: ?, pc: ?, predPc: ?, mask: ?, isStore: ?, isLoad: ?
  };
endfunction

function RobEntry invalidRobEntry();
  return RobEntry {
    valid: False, state: ?, pc: ?, inst: ?, pDst: ?, oldPdst: ?,
    iType: ?, excp: ?, isBranch: ?, isStore: ?, isCsr: ?,
    isTlb: ?, isSpecial: ?, mispredict: ?, correctTarget: ?
  };
endfunction

function LQEntry invalidLQEntry();
  return LQEntry {
    valid: False, robTag: ?, vaddr: ?, paddr: ?, done: ?, replay: ?
  };
endfunction
