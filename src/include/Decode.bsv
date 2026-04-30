import Types::*;
import ProcTypes::*;
import Vector::*;
`include "CsrAddr.bsv"

(* noinline *)
function DecodedInst decode(Instruction inst);
  // 1. Default values (equivalent to NEMU's invalid instruction state)
  DecodedInst dInst = DecodedInst{
    iType: Unsupported, aluFunc: tagged Invalid, muldivFunc: tagged Invalid, brFunc: NT,
    dst: tagged Invalid, src1: tagged Invalid, src2: tagged Invalid, csr: tagged Invalid,
    imm: tagged Invalid, cacheOp: tagged Invalid, mask: tagged Invalid
  };

  // 2. Field Extraction
  let rd = inst[4: 0];
  let rj = inst[9: 5];
  let rk = inst[14: 10];
  CsrIndx csrNum = inst[23: 10];

  Data si12 = signExtend(inst[21: 10]);
  Data ui12 = zeroExtend(inst[21: 10]);
  Data si20_12 = {inst[24: 5], 12'b0};
  Data si14_2 = signExtend({inst[23: 10], 2'b0});
  Data offs16 = signExtend({inst[25: 10], 2'b0});
  Data offs26 = signExtend({inst[9: 0], inst[25: 10], 2'b0});

  // 3. Flattened Decode Table (Exactly 32-bit matches)
  case (inst) matches
    // --- ALU 3R Format ---
    32'b000000_0000_01_00000_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid AddW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // ADD.W
    32'b000000_0000_01_00010_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid SubW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // SUB.W
    32'b000000_0000_01_00100_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid Slt; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // SLT
    32'b000000_0000_01_00101_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid Sltu; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // SLTU
    32'b000000_0000_01_01000_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid Nor_; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // NOR
    32'b000000_0000_01_01001_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid And_; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // AND
    32'b000000_0000_01_01010_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid Or_; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // OR
    32'b000000_0000_01_01011_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid Xor_; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // XOR
    32'b000000_0000_01_01110_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid SllW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // SLL.W
    32'b000000_0000_01_01111_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid SrlW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // SRL.W
    32'b000000_0000_01_10000_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid SraW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // SRA.W

    // --- MUL/DIV 3R Format ---
    32'b000000_0000_01_11000_?????_?????_?????: begin dInst.iType = Alu; dInst.muldivFunc = tagged Valid MulW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // MUL.W
    32'b000000_0000_01_11001_?????_?????_?????: begin dInst.iType = Alu; dInst.muldivFunc = tagged Valid MulhW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // MULH.W
    32'b000000_0000_01_11010_?????_?????_?????: begin dInst.iType = Alu; dInst.muldivFunc = tagged Valid MulhWu; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // MULH.WU
    32'b000000_0000_10_00000_?????_?????_?????: begin dInst.iType = Alu; dInst.muldivFunc = tagged Valid DivW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // DIV.W
    32'b000000_0000_10_00010_?????_?????_?????: begin dInst.iType = Alu; dInst.muldivFunc = tagged Valid DivWu; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // DIV.WU
    32'b000000_0000_10_00001_?????_?????_?????: begin dInst.iType = Alu; dInst.muldivFunc = tagged Valid ModW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // MOD.W
    32'b000000_0000_10_00011_?????_?????_?????: begin dInst.iType = Alu; dInst.muldivFunc = tagged Valid ModWu; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; end // MOD.WU

    // --- ALU Immediate ---
    32'b000000_1010_????????????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid AddW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; end // ADDI.W
    32'b000000_1000_????????????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid Slt; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; end // SLTI
    32'b000000_1001_????????????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid Sltu; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; end // SLTUI
    32'b000000_1101_????????????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid And_; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid ui12; end // ANDI
    32'b000000_1110_????????????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid Or_; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid ui12; end // ORI
    32'b000000_1111_????????????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid Xor_; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid ui12; end // XORI
    32'b000000_0001_00_00001_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid SllW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid zeroExtend(rk); end // SLLI.W
    32'b000000_0001_00_01001_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid SrlW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid zeroExtend(rk); end // SRLI.W
    32'b000000_0001_00_10001_?????_?????_?????: begin dInst.iType = Alu; dInst.aluFunc = tagged Valid SraW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid zeroExtend(rk); end // SRAI.W

    // --- Address Calculation ---
    32'b000101_0_????????????????????_?????: begin dInst.iType = Lu12i; dInst.dst = tagged Valid rd; dInst.imm = tagged Valid si20_12; end // LU12I.W
    32'b000111_0_????????????????????_?????: begin dInst.iType = Pcaddu12i; dInst.dst = tagged Valid rd; dInst.imm = tagged Valid si20_12; end // PCADDU12I

    // --- Load / Store ---
    32'b001010_0000_????????????_?????_?????: begin dInst.iType = Ld; dInst.aluFunc = tagged Valid AddW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; dInst.mask = tagged Valid 5'b10001; end // LD.B
    32'b001010_0001_????????????_?????_?????: begin dInst.iType = Ld; dInst.aluFunc = tagged Valid AddW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; dInst.mask = tagged Valid 5'b10011; end // LD.H
    32'b001010_0010_????????????_?????_?????: begin dInst.iType = Ld; dInst.aluFunc = tagged Valid AddW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; dInst.mask = tagged Valid 5'b11111; end // LD.W
    32'b001010_0100_????????????_?????_?????: begin dInst.iType = St; dInst.aluFunc = tagged Valid AddW; dInst.src2 = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; dInst.mask = tagged Valid 5'b10001; end // ST.B
    32'b001010_0101_????????????_?????_?????: begin dInst.iType = St; dInst.aluFunc = tagged Valid AddW; dInst.src2 = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; dInst.mask = tagged Valid 5'b10011; end // ST.H
    32'b001010_0110_????????????_?????_?????: begin dInst.iType = St; dInst.aluFunc = tagged Valid AddW; dInst.src2 = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; dInst.mask = tagged Valid 5'b11111; end // ST.W
    32'b001010_1000_????????????_?????_?????: begin dInst.iType = Ld; dInst.aluFunc = tagged Valid AddW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; dInst.mask = tagged Valid 5'b00001; end // LD.BU
    32'b001010_1001_????????????_?????_?????: begin dInst.iType = Ld; dInst.aluFunc = tagged Valid AddW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si12; dInst.mask = tagged Valid 5'b00011; end // LD.HU

    // --- Atomic / LLSC ---
    32'b001000_00_??????????????_?????_?????: begin dInst.iType = Ll; dInst.aluFunc = tagged Valid AddW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid si14_2; dInst.mask = tagged Valid 5'b11111; end // LL.W
    32'b001000_01_??????????????_?????_?????: begin dInst.iType = Sc; dInst.aluFunc = tagged Valid AddW; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rd; dInst.imm = tagged Valid si14_2; dInst.mask = tagged Valid 5'b11111; end // SC.W

    // --- CSR Instructions ---
    32'b000001_00_??????????????_00000_?????: begin dInst.iType = Csrr; dInst.dst = tagged Valid rd; dInst.csr = tagged Valid csrNum; end // CSRRD
    32'b000001_00_??????????????_00001_?????: begin dInst.iType = Csrw; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rd; dInst.csr = tagged Valid csrNum; end // CSRWR
    32'b000001_00_??????????????_?????_?????: begin dInst.iType = Csrxchg; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rd; dInst.src2 = tagged Valid rj; dInst.csr = tagged Valid csrNum; end // CSRXCHG

    // --- Privileged (TLB/ERTN/CACOP) ---
    32'b000001_1001_00_10000_01010_00000_00000: dInst.iType = Tlbsrch;
    32'b000001_1001_00_10000_01011_00000_00000: dInst.iType = Tlbrd;
    32'b000001_1001_00_10000_01100_00000_00000: dInst.iType = Tlbwr;
    32'b000001_1001_00_10000_01101_00000_00000: dInst.iType = Tlbfill;
    32'b000001_1001_00_10000_01110_00000_00000: dInst.iType = Ertn;
    32'b000001_1001_00_10001_?????_?????_?????: dInst.iType = Idle;
    32'b000001_1001_00_10011_?????_?????_????? &&& (rd <= 6): begin dInst.iType = Invtlb; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rk; dInst.imm = tagged Valid zeroExtend(rd); end // INVTLB
    32'b000001_1000_00_00000_?????_?????_?????: begin dInst.iType = Cacop; dInst.aluFunc = tagged Valid AddW; dInst.src1 = tagged Valid rj; dInst.csr = tagged Valid `CSR_CTAG; dInst.imm = tagged Valid si12; dInst.cacheOp = tagged Valid rd; end // CACOP

    // --- Jump / Branch ---
    32'b010101_??????????????????????????: begin dInst.iType = J; dInst.brFunc = AT; dInst.dst = tagged Valid 5'd1; dInst.imm = tagged Valid offs26; end // BL
    32'b010100_??????????????????????????: begin dInst.iType = J; dInst.brFunc = AT; dInst.imm = tagged Valid offs26; end // B
    32'b010011_????????????????_?????_?????: begin dInst.iType = Jr; dInst.brFunc = AT; dInst.dst = tagged Valid rd; dInst.src1 = tagged Valid rj; dInst.imm = tagged Valid offs16; end // JIRL
    32'b010110_????????????????_?????_?????: begin dInst.iType = Br; dInst.brFunc = Eq; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rd; dInst.imm = tagged Valid offs16; end // BEQ
    32'b010111_????????????????_?????_?????: begin dInst.iType = Br; dInst.brFunc = Neq; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rd; dInst.imm = tagged Valid offs16; end // BNE
    32'b011000_????????????????_?????_?????: begin dInst.iType = Br; dInst.brFunc = Lt; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rd; dInst.imm = tagged Valid offs16; end // BLT
    32'b011001_????????????????_?????_?????: begin dInst.iType = Br; dInst.brFunc = Ge; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rd; dInst.imm = tagged Valid offs16; end // BGE
    32'b011010_????????????????_?????_?????: begin dInst.iType = Br; dInst.brFunc = Ltu; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rd; dInst.imm = tagged Valid offs16; end // BLTU
    32'b011011_????????????????_?????_?????: begin dInst.iType = Br; dInst.brFunc = Geu; dInst.src1 = tagged Valid rj; dInst.src2 = tagged Valid rd; dInst.imm = tagged Valid offs16; end // BGEU

    // --- Timer / Counter ---
    32'b000000_0000_00_00000_11000_?????_00000 &&& (rj != 0): begin dInst.iType = RdCntId; dInst.dst = tagged Valid rj; dInst.csr = tagged Valid `CSR_TID; end // RDCNTID.W
    32'b000000_0000_00_00000_11000_00000_?????: begin dInst.iType = RdTimeL; dInst.dst =(rd != 0) ? tagged Valid rd: tagged Invalid; end // RDTIMEL.W
    32'b000000_0000_00_00000_11001_00000_?????: begin dInst.iType = RdTimeH; dInst.dst =(rd != 0) ? tagged Valid rd: tagged Invalid; end // RDTIMEH.W

    // --- Others / System ---
    32'b000000_0000_10_10110_?????_?????_?????: dInst.iType = Syscall; // SYSCALL (Form 1)
    32'b000000_0000_10_10100_?????_?????_?????: dInst.iType = Break; // BREAK (Form 1)
    32'b000000_0000_00_00000_00000_00000_01100: dInst.iType = Syscall; // SYSCALL (Form 2)
    32'b000000_0000_00_00000_00000_00000_01101: dInst.iType = Break; // BREAK (Form 2)
    32'b001110_0001_11_00100_?????_?????_?????: dInst.iType = Dbar;
    32'b001110_0001_11_00101_?????_?????_?????: dInst.iType = Ibar;

    default: dInst.iType = Unsupported;
  endcase

  return dInst;
endfunction
