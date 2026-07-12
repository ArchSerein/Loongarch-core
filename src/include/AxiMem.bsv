import Types::*;
import AxiTypes::*;
import MemoryService::*;
import Fifo::*;
`include "Autoconf.bsv"

typedef enum {
  AxiOwnerI,
  AxiOwnerD
} AxiOwner deriving(Bits, Eq);

typedef enum {
  RdIdle,
  RdResp
} AxiRdArbState deriving(Bits, Eq);

typedef enum {
  WrIdle,
  WrData,
  WrResp
} AxiWrArbState deriving(Bits, Eq);

// Merge I/D AXI masters into a single memory-facing AXI master.
// At most one outstanding transaction is supported (no ID interleave).
module mkAxiArbiter2#(AxiMemMaster iMem, AxiMemMaster dMem)(AxiMemMaster);
  Fifo#(2, AxiReadAddr)   arQ <- mkCFFifo;
  Fifo#(2, AxiWriteAddr)  awQ <- mkCFFifo;
  Fifo#(4, AxiWriteData)  wQ  <- mkCFFifo;

  Reg#(AxiRdArbState) rdState <- mkReg(RdIdle);
  Reg#(AxiOwner)      rdOwner <- mkReg(AxiOwnerI);

  Reg#(AxiWrArbState) wrState <- mkReg(WrIdle);
  Reg#(AxiOwner)      wrOwner <- mkReg(AxiOwnerD);

  // ====================================================================
  // WRITE CHANNEL ARBITRATION (AW, W, B)
  // ====================================================================
  
  rule startDWriteTxn (wrState == WrIdle && dMem.wrAddrValid);
    let aw <- dMem.wrAddr;
    awQ.enq(aw);
    wrOwner <= AxiOwnerD;
    wrState <= WrData;
  endrule

  rule startIWriteTxn (wrState == WrIdle && !dMem.wrAddrValid && iMem.wrAddrValid);
    let aw <- iMem.wrAddr;
    awQ.enq(aw);
    wrOwner <= AxiOwnerI;
    wrState <= WrData;
  endrule

  rule drainWriteDataD (wrState == WrData && wrOwner == AxiOwnerD && dMem.wrDataValid);
    let wd <- dMem.wrData;
    wQ.enq(wd);
    if (wd.last) begin
      wrState <= WrResp;
    end
  endrule

  rule drainWriteDataI (wrState == WrData && wrOwner == AxiOwnerI && iMem.wrDataValid);
    let wd <- iMem.wrData;
    wQ.enq(wd);
    if (wd.last) begin
      wrState <= WrResp;
    end
  endrule

  // ====================================================================
  // READ CHANNEL ARBITRATION (AR, R)
  // ====================================================================
  
  rule startDReadTxn (rdState == RdIdle && dMem.rdAddrValid);
    let ar <- dMem.rdAddr;
    arQ.enq(ar);
    rdOwner <= AxiOwnerD;
    rdState <= RdResp;
  endrule

  rule startIReadTxn (rdState == RdIdle && !dMem.rdAddrValid && iMem.rdAddrValid);
    let ar <- iMem.rdAddr;
    arQ.enq(ar);
    rdOwner <= AxiOwnerI;
    rdState <= RdResp;
  endrule

  // ====================================================================
  // AXI MASTER INTERFACE METHODS (Downstream)
  // ====================================================================

  method Bool rdAddrValid = arQ.notEmpty;

  method ActionValue#(AxiReadAddr) rdAddr;
    let x = arQ.first;
    arQ.deq;
    return x;
  endmethod

  method Action rdData(AxiReadData d) if (rdState == RdResp);
    if (rdOwner == AxiOwnerD) begin
      dMem.rdData(d);
    end else begin
      iMem.rdData(d);
    end
    if (d.last) begin
      rdState <= RdIdle;
    end
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

  method Action wrResp(AxiWriteResp r) if (wrState == WrResp);
    if (wrOwner == AxiOwnerD) begin
      dMem.wrResp(r);
    end else begin
      iMem.wrResp(r);
    end
    wrState <= WrIdle;
  endmethod
endmodule

`ifdef CONFIG_BSIM

typedef enum { SimRdIdle, SimRdRun } SimReadState deriving(Bits, Eq);
typedef enum { SimWrIdle, SimWrRun } SimWriteState deriving(Bits, Eq);

// Simulation-side adapter:
// consume AXI traffic and issue one word MemoryService request per beat.
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
    Addr wordAddr = { baseWordAddr + zeroExtend(rdSent), 2'b0 };
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
    Addr wordAddr = { baseWordAddr + zeroExtend(wrBeat), 2'b0 };
    if (wd.strb != 0) begin
      memSvc.writeReq(wordAddr, wd.data, {'b0, wd.strb});
    end

    Bool last = wd.last || (wrBeat == wrReq.len);
    if (last) begin
      axi.wrResp(AxiWriteResp{resp: AxiRespOkay});
      wrState <= SimWrIdle;
    end
    wrBeat <= wrBeat + 1;
  endrule
endmodule
`endif
