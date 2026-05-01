import Types::*;
import MemTypes::*;
import ProcTypes::*;
import Vector::*;

(* noinline *)
function Data alu(Data a, Data b, AluFunc func);
  Data res = case(func)
     AddW   : (a + b);
     SubW   : (a - b);
     Nor_   : ~(a | b);
     And_   : (a & b);
     Or_    : (a | b);
     Xor_   : (a ^ b);
     Slt    : zeroExtend( pack( signedLT(a, b) ) );
     Sltu   : zeroExtend( pack( a < b ) );
     SllW   : (a << b[4:0]);
     SrlW   : (a >> b[4:0]);
     SraW   : signedShiftRight(a, b[4:0]);
  endcase;
  return res;
endfunction


(* noinline *)
function Bool aluBr(Data a, Data b, BrFunc brFunc);
  Bool brTaken = case(brFunc)
    Eq  : (a == b);
    Neq : (a != b);
    Lt  : signedLT(a, b);
    Ltu : (a < b);
    Ge  : signedGE(a, b);
    Geu : (a >= b);
    AT  : True;
    NT  : False;
  endcase;
  return brTaken;
endfunction

(* noinline *)
function Addr brAddrCalc(Addr pc, Data val, IType iType, Data imm, Bool taken);
  Addr pcPlus4 = pc + 4;
  Addr targetAddr = case (iType)
    J  : (pc + imm);
    Jr : (val + imm);   // JIRL: GR[rj] + SignExt(offs16<<2)
    Br : (taken ? pc + imm : pcPlus4);
    default: pcPlus4;
  endcase;
  return targetAddr;
endfunction

(* noinline *)
function ExecInst exec(DecodedInst dInst, Data rVal1, Data rVal2, Addr pc, Addr ppc, Data csrVal);
  ExecInst eInst = ?;

  Data immVal = fromMaybe(0, dInst.imm);
  Data operand2 = isValid(dInst.imm) ? immVal : rVal2;
  Data execRes = isValid(dInst.aluFunc) ?
                   alu(rVal1, operand2, fromMaybe(?, dInst.aluFunc)) :
                   0;

  eInst.iType = dInst.iType;
  eInst.dst = dInst.dst;
  eInst.csr = dInst.csr;
  eInst.imm = dInst.imm;
  eInst.cacheOp = dInst.cacheOp;
  eInst.mask = dInst.mask;

  eInst.data = dInst.iType == Csrr ?
                 csrVal :
               dInst.iType == Cpucfg ?
                 csrVal :
               dInst.iType == Csrw ?
                 csrVal :
               dInst.iType == Csrxchg ?
                 csrVal :
               dInst.iType == RdCntId ?
                 csrVal :
               dInst.iType == Cacop ?
                 csrVal :
               (dInst.iType == St || dInst.iType == Sc) ?
                 rVal2 :
               dInst.iType == Invtlb ?
                 rVal1 :
               (dInst.iType == J || dInst.iType == Jr) ?
                 (pc + 4) :
               dInst.iType == Lu12i ?
                 immVal :
               dInst.iType == Pcaddu12i ?
                 (pc + immVal) :
                 execRes;

  // For CSR writes: carry the value to write to CSR in addr field
  if (dInst.iType == Csrw) begin
    eInst.addr = rVal1;
  end
  if (dInst.iType == Csrxchg) begin
    eInst.addr = (csrVal & (~rVal2)) | (rVal1 & rVal2);
  end

  let brTaken = aluBr(rVal1, rVal2, dInst.brFunc);
  let brAddr = brAddrCalc(pc, rVal1, dInst.iType, immVal, brTaken);

  if (dInst.iType != Csrw && dInst.iType != Csrxchg) begin
    eInst.addr = (case(dInst.iType)
      Invtlb: rVal2;
      default: execRes;
    endcase);
  end

  // CSR write-like ops repurpose addr; never mispredict for them
  eInst.mispredict = (dInst.iType == Csrw || dInst.iType == Csrxchg) ? False : (brAddr != ppc);
  eInst.brTaken = brTaken;
  eInst.targetAddr = brAddr;

  return eInst;
endfunction
