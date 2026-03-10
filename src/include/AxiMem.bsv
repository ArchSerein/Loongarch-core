import Types::*;
import CacheTypes::*;
import MemoryService::*;
import Fifo::*;

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
// - *_Valid + ActionValue methods expose requests from core to memory.
// - rdData/wrResp methods push memory responses back into core.
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

interface WideMemAxiBridge;
  interface WideMem wideMem;
  interface AxiMemMaster axi;
endinterface

typedef enum {
  BridgeIdle,
  BridgeReadWait,
  BridgeWriteSend,
  BridgeWriteWaitResp
} WideMemAxiState deriving(Bits, Eq);

// Converts cache-line style WideMem traffic into AXI bursts.
module mkWideMemToAxiBridge(WideMemAxiBridge);
  Fifo#(2, WideMemReq)    reqQ  <- mkCFFifo;
  Fifo#(2, WideMemResp)   respQ <- mkCFFifo;

  Fifo#(2, AxiReadAddr)   arQ <- mkCFFifo;
  Fifo#(4, AxiReadData)   rQ  <- mkCFFifo;
  Fifo#(2, AxiWriteAddr)  awQ <- mkCFFifo;
  Fifo#(4, AxiWriteData)  wQ  <- mkCFFifo;
  Fifo#(2, AxiWriteResp)  bQ  <- mkCFFifo;

  Reg#(WideMemAxiState) state <- mkReg(BridgeIdle);
  Reg#(WideMemReq)      activeReq <- mkRegU;
  Reg#(Bit#(8))         beatIdx <- mkReg(0);
  Reg#(WideMemResp)     readLine <- mkReg(replicate(0));

  rule startReq (state == BridgeIdle && reqQ.notEmpty);
    let req = reqQ.first;
    activeReq <= req;
    beatIdx <= 0;

    if (req.write_en == 0) begin
      arQ.enq(AxiReadAddr{
        addr: req.addr,
        len: req.burst_len - 1,
        size: 3'd2,
        burst: AxiBurstIncr
      });
      readLine <= replicate(0);
      state <= BridgeReadWait;
    end
    else begin
      awQ.enq(AxiWriteAddr{
        addr: req.addr,
        len: req.burst_len - 1,
        size: 3'd2,
        burst: AxiBurstIncr
      });
      state <= BridgeWriteSend;
    end
  endrule

  rule collectReadData (state == BridgeReadWait && rQ.notEmpty);
    let beat = rQ.first;
    rQ.deq;

    Bit#(TLog#(MemBurstWords)) idx = truncate(beatIdx);
    WideMemResp nextLine = update(readLine, idx, beat.data);
    Bit#(8) nextBeat = beatIdx + 1;

    readLine <= nextLine;
    beatIdx <= nextBeat;

    if (beat.last || nextBeat == activeReq.burst_len) begin
      respQ.enq(nextLine);
      reqQ.deq;
      state <= BridgeIdle;
    end
  endrule

  rule sendWriteData (state == BridgeWriteSend && wQ.notFull);
    Bit#(TLog#(MemBurstWords)) idx = truncate(beatIdx);
    Bit#(8) nextBeat = beatIdx + 1;
    Bool isLast = (nextBeat == activeReq.burst_len);

    Bit#(WordSz) strb = activeReq.write_en[idx] == 1 ? '1 : 0;
    wQ.enq(AxiWriteData{
      data: activeReq.data[idx],
      strb: strb,
      last: isLast
    });

    if (isLast) begin
      state <= BridgeWriteWaitResp;
    end
    beatIdx <= nextBeat;
  endrule

  rule recvWriteResp (state == BridgeWriteWaitResp && bQ.notEmpty);
    bQ.deq;
    reqQ.deq;
    state <= BridgeIdle;
  endrule

  interface WideMem wideMem;
    method Action req(WideMemReq r);
      reqQ.enq(r);
    endmethod

    method ActionValue#(WideMemResp) resp;
      let x = respQ.first;
      respQ.deq;
      return x;
    endmethod

    method Bool respValid = respQ.notEmpty;
  endinterface

  interface AxiMemMaster axi;
    method Bool rdAddrValid = arQ.notEmpty;

    method ActionValue#(AxiReadAddr) rdAddr;
      let x = arQ.first;
      arQ.deq;
      return x;
    endmethod

    method Action rdData(AxiReadData d);
      rQ.enq(d);
    endmethod

    method Bool wrAddrValid = awQ.notEmpty;

    method ActionValue#(AxiWriteAddr) wrAddr;
      let x = awQ.first;
      awQ.deq;
      return x;
    endmethod

    method Bool wrDataValid = wQ.notEmpty;

    method ActionValue#(AxiWriteData) wrData;
      let x = wQ.first;
      wQ.deq;
      return x;
    endmethod

    method Action wrResp(AxiWriteResp r);
      bQ.enq(r);
    endmethod
  endinterface
endmodule

typedef enum { SimRdIdle, SimRdRun } SimReadState deriving(Bits, Eq);
typedef enum { SimWrIdle, SimWrRun } SimWriteState deriving(Bits, Eq);

// Simulation-side adapter:
// consume AXI bursts and issue one word MemoryService transaction per beat.
module mkAxiMemSimBridge#(AxiMemMaster axi, MemoryService memSvc)(Empty);
  Reg#(SimReadState) rdState <- mkReg(SimRdIdle);
  Reg#(AxiReadAddr)  rdReq <- mkRegU;
  Reg#(Bit#(8))      rdSent <- mkReg(0);
  Reg#(Bit#(8))      rdRecv <- mkReg(0);

  Reg#(SimWriteState) wrState <- mkReg(SimWrIdle);
  Reg#(AxiWriteAddr)  wrReq <- mkRegU;
  Reg#(Bit#(8))       wrBeat <- mkReg(0);

  rule startRead (rdState == SimRdIdle && axi.rdAddrValid);
    let ar <- axi.rdAddr;
    rdReq <= ar;
    rdSent <= 0;
    rdRecv <= 0;
    rdState <= SimRdRun;
  endrule

  rule issueReadReq (rdState == SimRdRun && rdSent <= rdReq.len);
    Bit#(TSub#(AddrSz, 2)) baseWordAddr = truncateLSB(rdReq.addr);
    Addr wordAddr = zeroExtend(baseWordAddr) + zeroExtend(rdSent);
    memSvc.readReq(wordAddr);
    rdSent <= rdSent + 1;
  endrule

  rule sendReadData (rdState == SimRdRun && memSvc.readRespValid);
    let d <- memSvc.readResp;
    Bool last = (rdRecv == rdReq.len);
    axi.rdData(AxiReadData{data: d, resp: AxiRespOkay, last: last});
    if (last) begin
      rdState <= SimRdIdle;
    end
    rdRecv <= rdRecv + 1;
  endrule

  rule startWrite (wrState == SimWrIdle && axi.wrAddrValid);
    let aw <- axi.wrAddr;
    wrReq <= aw;
    wrBeat <= 0;
    wrState <= SimWrRun;
  endrule

  rule issueWriteData (wrState == SimWrRun && axi.wrDataValid);
    let wd <- axi.wrData;
    Bit#(TSub#(AddrSz, 2)) baseWordAddr = truncateLSB(wrReq.addr);
    Addr wordAddr = zeroExtend(baseWordAddr) + zeroExtend(wrBeat);
    if (wd.strb != 0) begin
      memSvc.writeReq(wordAddr, wd.data);
    end

    Bool last = wd.last || (wrBeat == wrReq.len);
    if (last) begin
      axi.wrResp(AxiWriteResp{resp: AxiRespOkay});
      wrState <= SimWrIdle;
    end
    wrBeat <= wrBeat + 1;
  endrule
endmodule
