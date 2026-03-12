import GetPut::*;
import Types::*;
import Memory::*;

typedef Data MemResp;

typedef enum{Ld, St, Lr, Sc, Fence} MemOp deriving(Eq, Bits, FShow);
typedef struct{
    MemOp op;
    Addr  addr;
    Data  data;
} MemReq deriving(Eq, Bits, FShow);

typedef struct {
    Addr addr;
    Data data;
} MemInitLoad deriving(Eq, Bits, FShow);

typedef union tagged {
    MemInitLoad InitLoad;
    void InitDone;
} MemInit deriving(Eq, Bits, FShow);

interface MemInitIfc;
    interface Put#(MemInit) request;
    method Bool done();
endinterface
