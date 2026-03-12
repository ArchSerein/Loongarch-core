import Types::*;

// Host-facing asynchronous word memory service.
interface MemoryService;
    method Action writeReq(Addr wordAddr, Data data, Bit#(8) mask);
    method Action readReq(Addr wordAddr);
    method Bool readRespValid;
    method ActionValue#(Data) readResp;
endinterface
