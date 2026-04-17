import Types::*;
import ProcTypes::*;
`include "Autoconf.bsv"

typedef 4 StoreBufEntries;

typedef struct {
  Addr          addr;
  Data          data;
  Bit#(WordSz)  byteEn;
} StoreBufEntry deriving(Bits, Eq);

typedef struct {
  Data          data;
  Bit#(WordSz)  byteEn;
} StoreForwardResult deriving(Bits, Eq);

typedef enum {
  PipeMemResp,
  StoreDrainResp
} DCacheRespSrc deriving(Bits, Eq);

typedef struct {
  Addr        pc;
  Addr        predPc;
  Bool        fEpoch;
  ExcpInfo    excp;
}   F2D deriving(Bits, Eq);

typedef struct {
  Addr        pc;
  Addr        predPc;
  Bool        dEpoch;
`ifdef CONFIG_DIFFTEST
  Instruction inst;
`endif
  DecodedInst dInst;
  ExcpInfo    excp;
}   D2R deriving(Bits, Eq);

typedef struct {
  Addr        pc;
  Addr        predPc;
  Bool        rEpoch;
`ifdef CONFIG_DIFFTEST
  Instruction inst;
`endif
  Data        rVal1;
  Data        rVal2;
  Data        csrVal;
  DecodedInst rInst;
  ExcpInfo    excp;
}   R2E deriving(Bits, Eq);

typedef struct {
  Addr                pc;
`ifdef CONFIG_DIFFTEST
  Instruction         inst;
  Maybe#(DiffMemOp)   diffMem;
`endif
  ExcpInfo            excp;
  Maybe#(ByteMask)    mask;
  Bool                memRespNeeded;
  Addr                memPaddr;
  StoreForwardResult  storeForward;
  Maybe#(ExecInst)    eInst;
}   E2M deriving(Bits, Eq);

typedef struct {
  Addr                pc;
`ifdef CONFIG_DIFFTEST
  Instruction         inst;
`endif
  ExcpInfo            excp;
`ifdef CONFIG_DIFFTEST
  Maybe#(DiffMemOp)   diffMem;
`endif
  Addr                memPaddr;
  Maybe#(ExecInst)    mInst;
}   M2W deriving(Bits, Eq);

typedef struct {
  Bool      valid;
  Bit#(6)   ecode;
  Bit#(9)   esubcode;
  Addr      badv;
} ExcpInfo deriving(Bits, Eq);

Addr startpc = 32'h1c000000;
