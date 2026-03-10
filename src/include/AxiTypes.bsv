import Types::*;

typedef enum {
  AxiRespOkay  = 2'b00,
  AxiRespExOkay = 2'b01,
  AxiRespSlvErr = 2'b10,
  AxiRespDecErr = 2'b11
} AxiResp deriving(Bits, Eq);

typedef enum {
  AxiBurstFixed = 2'b00,
  AxiBurstIncr  = 2'b01,
  AxiBurstWrap  = 2'b10
} AxiBurst deriving(Bits, Eq);

typedef struct {
  Addr      addr;
  Bit#(8)   len;   // AXI: beats-1
  Bit#(3)   size;  // bytes per beat = 2^size
  AxiBurst  burst;
} AxiReadAddr deriving(Bits, Eq);

typedef struct {
  Data      data;
  AxiResp   resp;
  Bool      last;
} AxiReadData deriving(Bits, Eq);

typedef struct {
  Addr      addr;
  Bit#(8)   len;   // AXI: beats-1
  Bit#(3)   size;  // bytes per beat = 2^size
  AxiBurst  burst;
} AxiWriteAddr deriving(Bits, Eq);

typedef struct {
  Data          data;
  Bit#(WordSz)  strb;
  Bool          last;
} AxiWriteData deriving(Bits, Eq);

typedef struct {
  AxiResp resp;
} AxiWriteResp deriving(Bits, Eq);

// Queue-style AXI master view.
// - *_Valid + ActionValue methods expose requests from producer to consumer.
// - rdData/wrResp methods push memory responses back to producer.
interface AxiMemMaster;
  method Bool rdAddrValid;
  method ActionValue#(AxiReadAddr) rdAddr;
  method Action rdData(AxiReadData d);

  method Bool wrAddrValid;
  method ActionValue#(AxiWriteAddr) wrAddr;
  method Bool wrDataValid;
  method ActionValue#(AxiWriteData) wrData;
  method Action wrResp(AxiWriteResp r);
endinterface
