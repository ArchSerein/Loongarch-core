import Types::*;
import FShow::*;

typedef enum {
  ExitCode = 2'd0,
  PrintChar = 2'd1,
  PrintIntLow = 2'd2,
  PrintIntHigh = 2'd3
} CpuToHostType deriving(Bits, Eq, FShow);

typedef struct {
  CpuToHostType c2hType;
  Bit#(16) data;
} CpuToHostData deriving(Bits, Eq, FShow);

typedef struct {
  Addr pc;
  Instruction inst;
  Bool wen;
  Bit#(5) wdest;
  Data wdata;
} DiffCommit deriving(Bits, Eq, FShow);

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

  Fence, // DBAR / IBAR

  Break // debug
} IType deriving(Bits, Eq, FShow);

typedef enum {
  Eq,
  Neq,
  Lt,
  Ltu,
  Ge,
  Geu,
  AT,
  NT
} BrFunc deriving(Bits, Eq, FShow);

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
} AluFunc deriving(Bits, Eq, FShow);

typedef enum {
  MulW,
  MulhW,
  MulhWu,
  DivW,
  DivWu,
  ModW,
  ModWu
} MulDivFunc deriving(Bits, Eq, FShow);

typedef void Exception;

typedef struct {
  Addr pc;
  Addr nextPc;
  IType brType;
  Bool taken;
  Bool mispredict;
} Redirect deriving(Bits, Eq, FShow);

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
} DecodedInst deriving(Bits, Eq, FShow);

typedef struct {
  IType            iType;
  Maybe#(RIndx)    dst;
  Maybe#(CsrIndx)  csr;
  Data             data;
  Addr             addr;
  Bool             mispredict;
  Bool             brTaken;
} ExecInst deriving(Bits, Eq, FShow);

function Bool dataHazard(Maybe#(RIndx) src1, Maybe#(RIndx) src2, Maybe#(RIndx)
  dst);
  return(isValid(dst) && ((isValid(src1) && fromMaybe(?, dst) == fromMaybe(?,
    src1)) ||
    (isValid(src2) && fromMaybe(?, dst) == fromMaybe(?, src2))));
endfunction

function Fmt showInst(Instruction inst);
  Fmt ret = $format("");

  Op_31_26 op6 = inst[31:26];
  Op_25_22 op4 = inst[25:22];
  Op_21_20 op2 = inst[21:20];
  Op_19_15 op5 = inst[19:15];
  let rd = inst[4:0];
  let rj = inst[9:5];
  let rk = inst[14:10];

  Data si12 = signExtend(inst[21:10]);
  Data ui12 = zeroExtend(inst[21:10]);
  Data si20_12 = { inst[24:5], 12'b0};
  Data offs16 = signExtend({ inst[25:10], 2'b0});
  Data offs26 = signExtend({ inst[9:0], inst[25:10], 2'b0});

  case (op6)
    6'b000000: begin
      if (op4 == 4'b0000 && op2 == 2'b01) begin
        ret = case (op5)
        5'b00000: $format("add.w");
        5'b00010: $format("sub.w");
        5'b00100: $format("slt");
        5'b00101: $format("sltu");
        5'b01000: $format("nor");
        5'b01001: $format("and");
        5'b01010: $format("or");
        5'b01011: $format("xor");
        5'b01110: $format("sll.w");
        5'b01111: $format("srl.w");
        5'b10000: $format("sra.w");
        default: $format("unsup-3R 0x%0x", inst);
      endcase;
      ret = ret + $format(" r%0d, r%0d, r%0d", rd, rj, rk);
    end
    else if (op4 == 4'b0001 && op2 == 2'b00) begin
      ret = case (op5)
      5'b00001: $format("slli.w");
      5'b01001: $format("srli.w");
      5'b10001: $format("srai.w");
      default: $format("unsup-shift 0x%0x", inst);
    endcase;
    ret = ret + $format(" r%0d, r%0d, %0d", rd, rj, inst[14:10]);
  end
  else begin
    ret = case (op4)
    4'b1010: $format("addi.w r%0d, r%0d, 0x%0x", rd, rj, si12);
    4'b1000: $format("slti r%0d, r%0d, 0x%0x", rd, rj, si12);
    4'b1001: $format("sltui r%0d, r%0d, 0x%0x", rd, rj, si12);
    4'b1101: $format("andi r%0d, r%0d, 0x%0x", rd, rj, ui12);
    4'b1110: $format("ori r%0d, r%0d, 0x%0x", rd, rj, ui12);
    4'b1111: $format("xori r%0d, r%0d, 0x%0x", rd, rj, ui12);
    default: $format("unsup-imm 0x%0x", inst);
  endcase;
end
end

  6'b000101: begin
    if (inst[25] == 0)
    ret = $format("lu12i.w r%0d, 0x%0x", rd, inst[24:5]);
    else
    ret = $format("unsup 0x%0x", inst);
  end

  6'b000111: begin
    if (inst[25] == 0)
    ret = $format("pcaddu12i r%0d, 0x%0x", rd, inst[24:5]);
    else
    ret = $format("unsup 0x%0x", inst);
  end

  6'b001010: begin
    case (op4)
      4'b0010: ret = $format("ld.w r%0d, [r%0d + 0x%0x]", rd, rj, si12);
      4'b0110: ret = $format("st.w [r%0d + 0x%0x], r%0d", rj, si12, rd);
      default: ret = $format("unsup-ldst 0x%0x", inst);
    endcase
  end

  6'b001000: begin
    Op_25_24 op24 = inst[25:24];
    Bit#(32) imm  = signExtend({inst[23:10], 2'b0});
    case (op24)
      2'b00: ret = $format("ll.w r%0d, [r%0d + 0x%0x]", rd, rj, imm);
      2'b01: ret = $format("sc.w r%0d, [r%0d + 0x%0x]", rd, rj, imm);
      default: ret = $format("unsup-llsc 0x%0x", inst);
    endcase
  end

  6'b000001: begin
    if (inst[25:24] == 2'b00) begin
      if (rj == 5'd0)
      ret = $format("csrrd r%0d, csr0x%0x", rd, inst[23:10]);
      else if (rj == 5'd1)
      ret = $format("csrwr r%0d, csr0x%0x", rd, inst[23:10]);
      else
      ret = $format("csrxchg r%0d, r%0d, csr0x%0x", rd, rj, inst[23:10]);
    end
    else
    ret = $format("unsup-csr 0x%0x", inst);
  end

  6'b010100: ret = $format("b 0x%0x", offs26);
  6'b010101: ret = $format("bl 0x%0x", offs26);
  6'b010011: ret = $format("jirl r%0d, r%0d, 0x%0x", rd, rj, offs16);

  6'b010110: ret = $format("beq r%0d, r%0d, 0x%0x", rj, rd, offs16);
  6'b010111: ret = $format("bne r%0d, r%0d, 0x%0x", rj, rd, offs16);
  6'b011000: ret = $format("blt r%0d, r%0d, 0x%0x", rj, rd, offs16);
  6'b011001: ret = $format("bge r%0d, r%0d, 0x%0x", rj, rd, offs16);
  6'b011010: ret = $format("bltu r%0d, r%0d, 0x%0x", rj, rd, offs16);
  6'b011011: ret = $format("bgeu r%0d, r%0d, 0x%0x", rj, rd, offs16);

  6'b001110: begin
    if (op4 == 4'b0001 && op2 == 2'b11) begin
      case (op5)
        5'b00100: ret = $format("dbar 0x%0x", inst[14:0]);
        5'b00101: ret = $format("ibar 0x%0x", inst[14:0]);
        default: ret = $format("unsup-bar 0x%0x", inst);
      endcase
    end
    else
    ret = $format("unsup 0x%0x", inst);
  end

  default: ret = $format("unsup 0x%0x", inst);
endcase

  return ret;
endfunction
