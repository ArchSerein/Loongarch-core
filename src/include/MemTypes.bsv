import GetPut::*;
import Types::*;
import Memory::*;

typedef Data MemResp;

typedef enum{Ld, St, Ll, Sc, Barrier, Cacop} MemOp deriving(Eq, Bits);
typedef struct{
    MemOp op;
    Addr  addr;   // virtual address for cache index/word select
    Addr  paddr;  // physical address for tag compare and external memory
    Bool  useCache;
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
