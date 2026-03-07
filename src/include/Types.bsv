import Vector::*;

typedef 32 AddrSz;
typedef Bit#(AddrSz) Addr;

typedef 32 DataSz;
typedef Bit#(DataSz) Data;

typedef 32 InstSz;
typedef Bit#(InstSz) Instruction;

// Single-core; kept for external module (CacheTypes) compatibility
typedef 1 CoreNum;
typedef Bit#(TLog#(CoreNum)) CoreID;
