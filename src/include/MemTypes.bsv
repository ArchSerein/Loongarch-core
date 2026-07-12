import GetPut::*;
import Types::*;

typedef Data MemResp;

typedef enum{Ld, St, Ll, Sc, Barrier, Cacop} MemOp deriving(Eq, Bits);

function Bit#(3) memByteEnToAxiSize(Bit#(WordSz) byteEn);
    case (byteEn)
        4'b1111: return 3'd2;
        4'b0011, 4'b1100: return 3'd1;
        default: return 3'd0;
    endcase
endfunction
typedef struct{
    MemOp op;
    Addr  addr;   // virtual address for cache index/word select
    Addr  paddr;  // physical address for tag compare and external memory
    Bool  useCache;
    Data  data;
    Bit#(WordSz) byteEn;
    Bit#(3) size;
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
