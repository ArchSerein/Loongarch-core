import Vector::*;

typedef 32 AddrSz;
typedef Bit#(AddrSz) Addr;

typedef 32 DataSz;
typedef Bit#(DataSz) Data;

typedef 32 InstSz;
typedef Bit#(InstSz) Instruction;

`ifndef CORE_NUM
`define CORE_NUM 1
`endif

typedef `CORE_NUM CoreNum;
typedef Bit#(TLog#(CoreNum)) CoreID;
