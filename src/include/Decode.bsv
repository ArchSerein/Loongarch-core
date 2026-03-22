import Types::*;
import ProcTypes::*;
import Vector::*;

(* noinline *)
function DecodedInst decode(Instruction inst);
  DecodedInst dInst = DecodedInst{
    iType: Unsupported,
    aluFunc: tagged Invalid,
    muldivFunc: tagged Invalid,
    brFunc: NT,
    dst: tagged Invalid,
    src1: tagged Invalid,
    src2: tagged Invalid,
    csr: tagged Invalid,
    imm: tagged Invalid
  };

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
    6'b000000: begin
      if (op_25_22 == 4'b0000 && op_21_20 == 2'b01) begin
        dInst.iType = Alu;
        dInst.dst   = tagged Valid rd;
        dInst.src1  = tagged Valid rj;
        dInst.src2  = tagged Valid rk;

        case (op_19_15)
          5'b00000: dInst.aluFunc    = tagged Valid AddW;
          5'b00010: dInst.aluFunc    = tagged Valid SubW;
          5'b00100: dInst.aluFunc    = tagged Valid Slt;
          5'b00101: dInst.aluFunc    = tagged Valid Sltu;
          5'b01000: dInst.aluFunc    = tagged Valid Nor_;
          5'b01001: dInst.aluFunc    = tagged Valid And_;
          5'b01010: dInst.aluFunc    = tagged Valid Or_;
          5'b01011: dInst.aluFunc    = tagged Valid Xor_;
          5'b01110: dInst.aluFunc    = tagged Valid SllW;
          5'b01111: dInst.aluFunc    = tagged Valid SrlW;
          5'b10000: dInst.aluFunc    = tagged Valid SraW;
          5'b11000: dInst.muldivFunc = tagged Valid MulW;
          5'b11001: dInst.muldivFunc = tagged Valid MulhW;
          5'b11010: dInst.muldivFunc = tagged Valid MulhWu;
          default:  dInst.iType      = Unsupported;
        endcase
      end
      else if (op_25_22 == 4'b0000 && op_21_20 == 2'b10) begin
        case (op_19_15)
          5'h00: begin
            dInst.iType      = Alu;
            dInst.dst        = tagged Valid rd;
            dInst.src1       = tagged Valid rj;
            dInst.src2       = tagged Valid rk;
            dInst.muldivFunc = tagged Valid DivW;
          end
          5'h01: begin
            dInst.iType      = Alu;
            dInst.dst        = tagged Valid rd;
            dInst.src1       = tagged Valid rj;
            dInst.src2       = tagged Valid rk;
            dInst.muldivFunc = tagged Valid ModW;
          end
          5'h02: begin
            dInst.iType      = Alu;
            dInst.dst        = tagged Valid rd;
            dInst.src1       = tagged Valid rj;
            dInst.src2       = tagged Valid rk;
            dInst.muldivFunc = tagged Valid DivWu;
          end
          5'h03: begin
            dInst.iType      = Alu;
            dInst.dst        = tagged Valid rd;
            dInst.src1       = tagged Valid rj;
            dInst.src2       = tagged Valid rk;
            dInst.muldivFunc = tagged Valid ModWu;
          end
          5'h14: dInst.iType = Break;
          5'h16: dInst.iType = Syscall;
          default: dInst.iType = Unsupported;
        endcase
      end
      else if (op_25_22 == 4'b0001 && op_21_20 == 2'b00) begin
        dInst.iType = Alu;
        dInst.dst   = tagged Valid rd;
        dInst.src1  = tagged Valid rj;
        dInst.imm   = tagged Valid zeroExtend(inst[14:10]);

        case (op_19_15)
          5'b00001: dInst.aluFunc = tagged Valid SllW;
          5'b01001: dInst.aluFunc = tagged Valid SrlW;
          5'b10001: dInst.aluFunc = tagged Valid SraW;
          default:  dInst.iType   = Unsupported;
        endcase
      end
      else begin
        dInst.iType = Alu;
        dInst.dst   = tagged Valid rd;
        dInst.src1  = tagged Valid rj;

        case (op_25_22)
          4'b1010: begin dInst.aluFunc = tagged Valid AddW; dInst.imm = tagged Valid si12; end
          4'b1000: begin dInst.aluFunc = tagged Valid Slt;  dInst.imm = tagged Valid si12; end
          4'b1001: begin dInst.aluFunc = tagged Valid Sltu; dInst.imm = tagged Valid si12; end
          4'b1101: begin dInst.aluFunc = tagged Valid And_; dInst.imm = tagged Valid ui12; end
          4'b1110: begin dInst.aluFunc = tagged Valid Or_;  dInst.imm = tagged Valid ui12; end
          4'b1111: begin dInst.aluFunc = tagged Valid Xor_; dInst.imm = tagged Valid ui12; end
          default:  dInst.iType = Unsupported;
        endcase
      end
    end

    6'b000101: begin
      if (inst[25] == 0) begin
        dInst.iType = Lu12i;
        dInst.dst   = tagged Valid rd;
        dInst.imm   = tagged Valid si20_12;
      end
    end

    6'b000111: begin
      if (inst[25] == 0) begin
        dInst.iType = Pcaddu12i;
        dInst.dst   = tagged Valid rd;
        dInst.imm   = tagged Valid si20_12;
      end
    end

    6'b001010: begin
      case (op_25_22)
        4'b0010: begin
          dInst.iType   = Ld;
          dInst.aluFunc = tagged Valid AddW;
          dInst.dst     = tagged Valid rd;
          dInst.src1    = tagged Valid rj;
          dInst.imm     = tagged Valid si12;
        end
        4'b0110: begin
          dInst.iType   = St;
          dInst.aluFunc = tagged Valid AddW;
          dInst.src1    = tagged Valid rj;
          dInst.src2    = tagged Valid rd;
          dInst.imm     = tagged Valid si12;
        end
        default: dInst.iType = Unsupported;
      endcase
    end

    6'b001000: begin
      Op_25_24 op_25_24 = inst[25:24];
      dInst.aluFunc = tagged Valid AddW;
      dInst.dst     = tagged Valid rd;
      dInst.src1    = tagged Valid rj;
      dInst.imm     = tagged Valid si14_2;

      case (op_25_24)
        2'b00: dInst.iType = Ll;
        2'b01: begin
          dInst.iType = Sc;
          dInst.src2  = tagged Valid rd;
        end
        default: dInst.iType = Unsupported;
      endcase
    end

    6'b001110: begin
      if (op_25_22 == 4'b0001 && op_21_20 == 2'b11) begin
        case (op_19_15)
          5'b00100, 5'b00101: dInst.iType = Fence;
          default: dInst.iType = Unsupported;
        endcase
      end
    end

    6'b000001: begin
      if (op_25_22 == 4'h9 && op_21_20 == 2'h0 && op_19_15 == 5'h10 &&
          rk == 5'h0e && rj == 5'd0 && rd == 5'd0) begin
        dInst.iType = Ertn;
      end
      else if (inst[25:24] == 2'b00) begin
        CsrIndx csrNum = inst[23:10];

        if (rj == 5'd0) begin
          dInst.iType = Csrr;
          dInst.dst   = tagged Valid rd;
          dInst.csr   = tagged Valid csrNum;
        end
        else if (rj == 5'd1) begin
          dInst.iType = Csrw;
          dInst.dst   = tagged Valid rd;
          dInst.src1  = tagged Valid rd;
          dInst.csr   = tagged Valid csrNum;
        end
      end
    end

    6'b010101: begin
      dInst.iType  = J;
      dInst.brFunc = AT;
      dInst.dst    = tagged Valid 5'd1;
      dInst.imm    = tagged Valid offs26;
    end

    6'b010100: begin
      dInst.iType  = J;
      dInst.brFunc = AT;
      dInst.imm    = tagged Valid offs26;
    end

    6'b010011: begin
      dInst.iType  = Jr;
      dInst.brFunc = AT;
      dInst.dst    = tagged Valid rd;
      dInst.src1   = tagged Valid rj;
      dInst.imm    = tagged Valid offs16;
    end

    6'b010110, 6'b010111, 6'b011000, 6'b011001, 6'b011010, 6'b011011: begin
      dInst.iType = Br;
      dInst.src1  = tagged Valid rj;
      dInst.src2  = tagged Valid rd;
      dInst.imm   = tagged Valid offs16;

      case (op_31_26)
        6'b010110: dInst.brFunc = Eq;
        6'b010111: dInst.brFunc = Neq;
        6'b011000: dInst.brFunc = Lt;
        6'b011001: dInst.brFunc = Ge;
        6'b011010: dInst.brFunc = Ltu;
        6'b011011: dInst.brFunc = Geu;
        default:   dInst.iType  = Unsupported;
      endcase
    end

    default: dInst.iType = Unsupported;
  endcase

  if (dInst.dst matches tagged Valid .d &&& d == 0) begin
    dInst.dst = tagged Invalid;
  end

  return dInst;
endfunction
