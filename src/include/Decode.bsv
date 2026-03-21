import Types::*;
import ProcTypes::*;
import Vector::*;

(* noinline *)
function DecodedInst decode(Instruction inst);
  DecodedInst dInst = ?;

  // default: no CSR, no muldiv
  dInst.csr = tagged Invalid;
  dInst.muldivFunc = tagged Invalid;

  Op_31_26 op_31_26 = inst[31:26];
  Op_25_22 op_25_22 = inst[25:22];
  Op_21_20 op_21_20 = inst[21:20];
  Op_19_15 op_19_15 = inst[19:15];

  let rd = inst[4:0];
  let rj = inst[9:5];
  let rk = inst[14:10];

  Data si12    = signExtend(inst[21:10]);
  Data ui12    = zeroExtend(inst[21:10]);
  Data offs16  = signExtend({ inst[25:10], 2'b0 });
  Data offs26  = signExtend({ inst[9:0], inst[25:10], 2'b0 });
  Data si20_12 = { inst[24:5], 12'b0 };
  Data si14_2  = signExtend({ inst[23:10], 2'b0 });

  case (op_31_26)

    // ----------------------------------------------------------------
    // 000000: 3R ALU / shift-imm / 2RI12 immediate ALU
    // ----------------------------------------------------------------
    6'b000000: begin
      if (op_25_22 == 4'b0000 && op_21_20 == 2'b01) begin
        // 3R register-register ALU
        dInst.iType   = Alu;
        dInst.brFunc  = NT;
        dInst.dst     = tagged Valid rd;
        dInst.src1    = tagged Valid rj;
        dInst.src2    = tagged Valid rk;
        dInst.imm     = tagged Invalid;
        dInst.aluFunc = tagged Valid (case (op_19_15)
          5'b00000: AddW;
          5'b00010: SubW;
          5'b00100: Slt;
          5'b00101: Sltu;
          5'b01000: Nor_;
          5'b01001: And_;
          5'b01010: Or_;
          5'b01011: Xor_;
          5'b01110: SllW;
          5'b01111: SrlW;
          5'b10000: SraW;
          default:  AddW; // placeholder, overridden below
        endcase);
        if (op_19_15 != 5'b00000 && op_19_15 != 5'b00010 &&
            op_19_15 != 5'b00100 && op_19_15 != 5'b00101 &&
            op_19_15 != 5'b01000 && op_19_15 != 5'b01001 &&
            op_19_15 != 5'b01010 && op_19_15 != 5'b01011 &&
            op_19_15 != 5'b01110 && op_19_15 != 5'b01111 &&
            op_19_15 != 5'b10000)
          dInst.iType = Unsupported;
      end
      else if (op_25_22 == 4'b0000 && op_21_20 == 2'b10) begin
        case (op_19_15)
          5'h14: begin
            dInst.iType = Break;
            dInst.brFunc = NT;
            dInst.aluFunc = tagged Invalid;
            dInst.dst = tagged Invalid;
            dInst.src1 = tagged Invalid;
            dInst.src2 = tagged Invalid;
            dInst.imm = tagged Invalid;
          end
          5'h16: begin
            dInst.iType = Syscall;
            dInst.brFunc = NT;
            dInst.aluFunc = tagged Invalid;
            dInst.dst = tagged Invalid;
            dInst.src1 = tagged Invalid;
            dInst.src2 = tagged Invalid;
            dInst.imm = tagged Invalid;
          end
          default: dInst.iType = Unsupported;
        endcase
      end
      else if (op_25_22 == 4'b0001 && op_21_20 == 2'b00) begin
        // 2RI5 shift immediate: SLLI.W / SRLI.W / SRAI.W
        dInst.iType  = Alu;
        dInst.brFunc = NT;
        dInst.dst    = tagged Valid rd;
        dInst.src1   = tagged Valid rj;
        dInst.src2   = tagged Invalid;
        dInst.imm    = tagged Valid zeroExtend(inst[14:10]);
        dInst.aluFunc = tagged Valid (case (op_19_15)
          5'b00001: SllW;
          5'b01001: SrlW;
          5'b10001: SraW;
          default:  SllW;
        endcase);
        if (op_19_15 != 5'b00001 && op_19_15 != 5'b01001 &&
            op_19_15 != 5'b10001)
          dInst.iType = Unsupported;
      end
      else begin
        // 2RI12 immediate ALU
        dInst.iType  = Alu;
        dInst.brFunc = NT;
        dInst.dst    = tagged Valid rd;
        dInst.src1   = tagged Valid rj;
        dInst.src2   = tagged Invalid;

        case (op_25_22)
          4'b1010: begin dInst.aluFunc = tagged Valid AddW;  dInst.imm = tagged Valid si12; end
          4'b1000: begin dInst.aluFunc = tagged Valid Slt;   dInst.imm = tagged Valid si12; end
          4'b1001: begin dInst.aluFunc = tagged Valid Sltu;  dInst.imm = tagged Valid si12; end
          4'b1101: begin dInst.aluFunc = tagged Valid And_;   dInst.imm = tagged Valid ui12; end
          4'b1110: begin dInst.aluFunc = tagged Valid Or_;    dInst.imm = tagged Valid ui12; end
          4'b1111: begin dInst.aluFunc = tagged Valid Xor_;   dInst.imm = tagged Valid ui12; end
          default: begin dInst.iType = Unsupported; dInst.aluFunc = tagged Invalid; dInst.imm = tagged Invalid; end
        endcase
      end
    end

    // ----------------------------------------------------------------
    // 000101: LU12I.W (1RI20)
    // ----------------------------------------------------------------
    6'b000101: begin
      if (inst[25] == 0) begin
        dInst.iType   = Lu12i;
        dInst.aluFunc = tagged Invalid;
        dInst.brFunc  = NT;
        dInst.dst     = tagged Valid rd;
        dInst.src1    = tagged Invalid;
        dInst.src2    = tagged Invalid;
        dInst.imm     = tagged Valid si20_12;
      end
      else
        dInst.iType = Unsupported;
    end

    // ----------------------------------------------------------------
    // 000111: PCADDU12I (1RI20)
    // ----------------------------------------------------------------
    6'b000111: begin
      if (inst[25] == 0) begin
        dInst.iType   = Pcaddu12i;
        dInst.aluFunc = tagged Invalid;
        dInst.brFunc  = NT;
        dInst.dst     = tagged Valid rd;
        dInst.src1    = tagged Invalid;
        dInst.src2    = tagged Invalid;
        dInst.imm     = tagged Valid si20_12;
      end
      else
        dInst.iType = Unsupported;
    end

    // ----------------------------------------------------------------
    // 001010: LD.W / ST.W (2RI12)
    // ----------------------------------------------------------------
    6'b001010: begin
      case (op_25_22)
        4'b0010: begin
          dInst.iType   = Ld;
          dInst.aluFunc = tagged Valid AddW;
          dInst.brFunc  = NT;
          dInst.dst     = tagged Valid rd;
          dInst.src1    = tagged Valid rj;
          dInst.src2    = tagged Invalid;
          dInst.imm     = tagged Valid si12;
        end
        4'b0110: begin
          dInst.iType   = St;
          dInst.aluFunc = tagged Valid AddW;
          dInst.brFunc  = NT;
          dInst.dst     = tagged Invalid;
          dInst.src1    = tagged Valid rj;
          dInst.src2    = tagged Valid rd;
          dInst.imm     = tagged Valid si12;
        end
        default: dInst.iType = Unsupported;
      endcase
    end

    // ----------------------------------------------------------------
    // 001000: LL.W / SC.W (2RI14)
    // ----------------------------------------------------------------
    6'b001000: begin
      Op_25_24 op_25_24 = inst[25:24];
      dInst.aluFunc = tagged Valid AddW;
      dInst.brFunc  = NT;
      dInst.dst     = tagged Valid rd;
      dInst.src1    = tagged Valid rj;
      dInst.imm     = tagged Valid si14_2;

      case (op_25_24)
        2'b00: begin dInst.iType = Ll;  dInst.src2 = tagged Invalid; end
        2'b01: begin dInst.iType = Sc;  dInst.src2 = tagged Valid rd; end
        default: dInst.iType = Unsupported;
      endcase
    end

    // ----------------------------------------------------------------
    // 001110: DBAR / IBAR
    // ----------------------------------------------------------------
    6'b001110: begin
      if (op_25_22 == 4'b0001 && op_21_20 == 2'b11) begin
        case (op_19_15)
          5'b00100, 5'b00101: begin
            dInst.iType   = Fence;
            dInst.aluFunc = tagged Invalid;
            dInst.brFunc  = NT;
            dInst.dst     = tagged Invalid;
            dInst.src1    = tagged Invalid;
            dInst.src2    = tagged Invalid;
            dInst.imm     = tagged Invalid;
          end
          default: dInst.iType = Unsupported;
        endcase
      end
      else
        dInst.iType = Unsupported;
    end

    // ----------------------------------------------------------------
    // 000001: CSR instructions (CSRRD / CSRWR)
    // ----------------------------------------------------------------
    6'b000001: begin
      if (op_25_22 == 4'h9 && op_21_20 == 2'h0 && op_19_15 == 5'h10 &&
          rk == 5'h0e && rj == 5'd0 && rd == 5'd0) begin
        dInst.iType   = Ertn;
        dInst.aluFunc = tagged Invalid;
        dInst.brFunc  = NT;
        dInst.dst     = tagged Invalid;
        dInst.src1    = tagged Invalid;
        dInst.src2    = tagged Invalid;
        dInst.csr     = tagged Invalid;
        dInst.imm     = tagged Invalid;
      end
      else if (inst[25:24] == 2'b00) begin
        CsrIndx csrNum = inst[23:10];
        dInst.brFunc  = NT;
        dInst.aluFunc = tagged Invalid;
        dInst.src2    = tagged Invalid;
        dInst.imm     = tagged Invalid;

        if (rj == 5'd0) begin
          // CSRRD: rd = CSR[csrNum]
          dInst.iType = Csrr;
          dInst.dst   = tagged Valid rd;
          dInst.src1  = tagged Invalid;
          dInst.csr   = tagged Valid csrNum;
        end
        else if (rj == 5'd1) begin
          // CSRWR: old = CSR[csrNum]; CSR[csrNum] = rd; rd = old
          dInst.iType = Csrw;
          dInst.dst   = tagged Valid rd;
          dInst.src1  = tagged Valid rd;
          dInst.csr   = tagged Valid csrNum;
        end
        else begin
          dInst.iType = Unsupported;
          dInst.dst   = tagged Invalid;
          dInst.src1  = tagged Invalid;
          dInst.csr   = tagged Invalid;
        end
      end
      else
        dInst.iType = Unsupported;
    end

    // ----------------------------------------------------------------
    // 010101: BL (unconditional call, link in r1)
    // ----------------------------------------------------------------
    6'b010101: begin
      dInst.iType   = J;
      dInst.aluFunc = tagged Invalid;
      dInst.brFunc  = AT;
      dInst.dst     = tagged Valid 5'd1;
      dInst.src1    = tagged Invalid;
      dInst.src2    = tagged Invalid;
      dInst.imm     = tagged Valid offs26;
    end

    // ----------------------------------------------------------------
    // 010100: B (unconditional branch, no link)
    // ----------------------------------------------------------------
    6'b010100: begin
      dInst.iType   = J;
      dInst.aluFunc = tagged Invalid;
      dInst.brFunc  = AT;
      dInst.dst     = tagged Invalid;
      dInst.src1    = tagged Invalid;
      dInst.src2    = tagged Invalid;
      dInst.imm     = tagged Valid offs26;
    end

    // ----------------------------------------------------------------
    // 010011: JIRL (register-indirect jump-and-link)
    // ----------------------------------------------------------------
    6'b010011: begin
      dInst.iType   = Jr;
      dInst.aluFunc = tagged Invalid;
      dInst.brFunc  = AT;
      dInst.dst     = tagged Valid rd;
      dInst.src1    = tagged Valid rj;
      dInst.src2    = tagged Invalid;
      dInst.imm     = tagged Valid offs16;
    end

    // ----------------------------------------------------------------
    // 010110..011011: conditional branches
    // ----------------------------------------------------------------
    6'b010110, 6'b010111, 6'b011000, 6'b011001, 6'b011010, 6'b011011: begin
      dInst.iType   = Br;
      dInst.aluFunc = tagged Invalid;
      dInst.dst     = tagged Invalid;
      dInst.src1    = tagged Valid rj;
      dInst.src2    = tagged Valid rd;
      dInst.imm     = tagged Valid offs16;

      case (op_31_26)
        6'b010110: dInst.brFunc = Eq;
        6'b010111: dInst.brFunc = Neq;
        6'b011000: dInst.brFunc = Lt;
        6'b011001: dInst.brFunc = Ge;
        6'b011010: dInst.brFunc = Ltu;
        6'b011011: dInst.brFunc = Geu;
        default:   dInst.iType = Unsupported;
      endcase
    end

    // ----------------------------------------------------------------
    // default: unsupported
    // ----------------------------------------------------------------
    default: begin
      dInst.iType   = Unsupported;
      dInst.aluFunc = tagged Invalid;
      dInst.brFunc  = NT;
      dInst.dst     = tagged Invalid;
      dInst.src1    = tagged Invalid;
      dInst.src2    = tagged Invalid;
      dInst.imm     = tagged Invalid;
    end
  endcase

  // r0 is hardwired zero — never write to it
  if (dInst.dst matches tagged Valid .d &&& d == 0) begin
    dInst.dst = tagged Invalid;
  end

  return dInst;
endfunction
