import Types::*;

typedef enum {
  WideMemIdle,
  WideMemSendReadReq,
  WideMemWaitReadResp,
  WideMemSendWriteReq
} TbWideMemState deriving(Bits, Eq);

function Bit#(AddrSz) getLineBaseWordAddr(Addr addr);
  Bit#(AddrSz) baseWordAddr = truncateLSB(addr);
  for (Integer i = 0; i < valueOf(TLog#(CacheLineWords)); i = i + 1) begin
    baseWordAddr[i] = 0;
  end
  return baseWordAddr;
endfunction

module mkTbWideMem#(MemoryService memSvc)(WideMem);
  Fifo#(2, WideMemReq) reqQ <- mkCFFifo;
  Fifo#(2, CacheLine) respQ <- mkCFFifo;

  Reg#(TbWideMemState) state <- mkReg(WideMemIdle);
  Reg#(WideMemReq) activeReq <- mkRegU;
  Reg#(Bit#(AddrSz)) baseWordAddr <- mkRegU;
  Reg#(CacheWordSelect) wordIdx <- mkReg(0);
  Reg#(CacheLine) readLine <- mkReg(replicate(0));

  rule startReq (state == WideMemIdle && reqQ.notEmpty);
    let r = reqQ.first;
    let base = getLineBaseWordAddr(r.addr);

    reqQ.deq;
    activeReq <= r;
    baseWordAddr <= base;
    wordIdx <= 0;

    if (r.write_en == 0) begin
      state <= WideMemSendReadReq;
    end
    else begin
      state <= WideMemSendWriteReq;
    end
  endrule

  rule doSendReadReq (state == WideMemSendReadReq);
    Bit#(32) addr = zeroExtend(baseWordAddr) + zeroExtend(wordIdx);
    memSvc.readReq(addr);

    if (wordIdx == fromInteger(valueOf(CacheLineWords) - 1)) begin
      wordIdx <= 0;
      state <= WideMemWaitReadResp;
    end
    else begin
      wordIdx <= wordIdx + 1;
    end
  endrule

  rule doWaitReadResp (state == WideMemWaitReadResp && memSvc.readRespValid);
    let d <- memSvc.readResp;
    CacheLine nextLine = update(readLine, wordIdx, d);
    readLine <= nextLine;

    if (wordIdx == fromInteger(valueOf(CacheLineWords) - 1)) begin
      respQ.enq(nextLine);
      wordIdx <= 0;
      state <= WideMemIdle;
    end
    else begin
      wordIdx <= wordIdx + 1;
    end
  endrule

  rule doSendWriteReq (state == WideMemSendWriteReq);
    if (activeReq.write_en[wordIdx] == 1) begin
      Bit#(32) addr = zeroExtend(baseWordAddr) + zeroExtend(wordIdx);
      memSvc.writeReq(addr, activeReq.data[wordIdx]);
    end

    if (wordIdx == fromInteger(valueOf(CacheLineWords) - 1)) begin
      wordIdx <= 0;
      state <= WideMemIdle;
    end
    else begin
      wordIdx <= wordIdx + 1;
    end
  endrule

  method Action req(WideMemReq r);
    reqQ.enq(r);
  endmethod

  method ActionValue#(CacheLine) resp;
    let line = respQ.first;
    respQ.deq;
    return line;
  endmethod

  method Bool respValid = respQ.notEmpty;
endmodule
