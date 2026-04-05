import Types::*;
import CoreTypes::*;
import ProcTypes::*;
`include "Autoconf.bsv"

typedef struct {
  Addr        pc;
  Addr        predPc;
  Bool        bhtPred;
  ExcpInfo    excp;
}   F2D deriving(Bits, Eq);

typedef struct {
  Addr        pc;
  Addr        predPc;
  Bool        bhtPred;
  `IFDEF_DIFFTEST(Instruction inst);
  DecodedInst dInst;
  ExcpInfo    excp;
}   D2R deriving(Bits, Eq);

typedef struct {
  Addr        pc;
  Addr        predPc;
  Bool        bhtPred;
  `IFDEF_DIFFTEST(Instruction inst);
  Data        rVal1;
  Data        rVal2;
  Data        csrVal;
  DecodedInst rInst;
  ExcpInfo    excp;
}   R2E deriving(Bits, Eq);

typedef struct {
  Addr                pc;
  `IFDEF_DIFFTEST(Instruction inst);
  ExcpInfo            excp;
  Maybe#(ByteMask)    mask;
  Maybe#(ExecInst)    eInst;
}   E2M deriving(Bits, Eq);

typedef struct {
  Addr                pc;
  `IFDEF_DIFFTEST(Instruction inst);
  ExcpInfo            excp;
  Maybe#(ExecInst)    mInst;
}   M2W deriving(Bits, Eq);

typedef struct {
  Bool      valid;
  Bit#(6)   ecode;
  Bit#(9)   esubcode;
  Addr      badv;
} ExcpInfo deriving(Bits, Eq);

Addr START_PC = 32'h1c000000;