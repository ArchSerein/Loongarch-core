import GetPut::*;
import Types::*;
import Memory::*;

typedef Data MemResp;

typedef enum{Ld, St, Lr, Sc, Barrier, Cacop} MemOp deriving(Eq, Bits);
typedef struct{
    MemOp op;
    Addr  addr;
    Data  data;
    Bit#(WordSz) byteEn;
    Bit#(5) cacheOp;
} MemReq deriving(Eq, Bits);

typedef struct {
    Addr addr;
    Data data;
} MemInitLoad deriving(Eq, Bits);

typedef union tagged {
    MemInitLoad InitLoad;
    void InitDone;
} MemInit deriving(Eq, Bits);

interface MemInitIfc;
    interface Put#(MemInit) request;
    method Bool done();
endinterface
