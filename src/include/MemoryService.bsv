import Types::*;

// Host-facing asynchronous word memory service.
interface MemoryService;
    method Action writeReq(Bit#(32) wordAddr, Data data);
    method Action readReq(Bit#(32) wordAddr);
    method Bool readRespValid;
    method ActionValue#(Data) readResp;
endinterface
