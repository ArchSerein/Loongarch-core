import Types::*;
import Vector::*;
import CoreTypes::*;
import CoreFunc::*;
import Ehr::*;

interface StoreBuf#(numeric type n);
  method Bool notFull;
  method Bool notEmpty;
  method Action enq(StoreBufEntry x);
  method Action deq;
  method StoreBufEntry first;
  method StoreForwardResult forward(Addr addr);
  method Bool search(Addr addr);
  method Action clear;
endinterface

module mkStoreBuf(StoreBuf#(n)) provisos (Bits#(StoreBufEntry, entrySz));
  Vector#(n, Reg#(StoreBufEntry)) data <- replicateM(mkRegU);
  Reg#(Bit#(TLog#(n))) enqP <- mkReg(0);
  Reg#(Bit#(TLog#(n))) deqP <- mkReg(0);
  Reg#(Bit#(TAdd#(TLog#(n), 1))) count <- mkReg(0);

  Ehr#(4, Maybe#(StoreBufEntry)) enqReq <- mkEhr(tagged Invalid);
  Ehr#(4, Maybe#(Bool)) deqReq <- mkEhr(tagged Invalid);
  Ehr#(2, Maybe#(Bool)) clearReq <- mkEhr(tagged Invalid);

  Bit#(TLog#(n)) maxIndex = fromInteger(valueOf(n) - 1);
  Bit#(TAdd#(TLog#(n), 1)) depth = fromInteger(valueOf(n));

  function Bit#(TLog#(n)) nextPtr(Bit#(TLog#(n)) ptr);
    return (ptr == maxIndex) ? 0 : ptr + 1;
  endfunction

  function Bit#(TLog#(n)) prevPtr(Bit#(TLog#(n)) ptr);
    return (ptr == 0) ? maxIndex : ptr - 1;
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    if (isValid(clearReq[1])) begin
      enqP <= 0;
      deqP <= 0;
      count <= 0;
    end else begin
      Bit#(TLog#(n)) nextEnqP = enqP;
      Bit#(TLog#(n)) nextDeqP = deqP;
      Bit#(TAdd#(TLog#(n), 1)) nextCount = count;
      Bool doDeq = isValid(deqReq[3]) && count != 0;
      Bool oneEntryDrained = doDeq && count == 1;
      Bool didMerge = False;

      if (enqReq[3] matches tagged Valid .x) begin
        if (count != 0 && !oneEntryDrained) begin
          let tailP = prevPtr(enqP);
          let tail = data[tailP];
          if (coreSameWordAddr(tail.addr, x.addr)) begin
            data[tailP] <= StoreBufEntry{
              addr: tail.addr,
              data: coreApplyByteMask(tail.data, x.data, x.byteEn),
              byteEn: tail.byteEn | x.byteEn
            };
            didMerge = True;
          end
        end

        if (!didMerge) begin
          data[enqP] <= x;
          nextEnqP = nextPtr(enqP);
          nextCount = nextCount + 1;
        end
      end

      if (doDeq) begin
        nextDeqP = nextPtr(deqP);
        nextCount = nextCount - 1;
      end

      enqP <= nextEnqP;
      deqP <= nextDeqP;
      count <= nextCount;
    end

    clearReq[1] <= tagged Invalid;
    enqReq[3] <= tagged Invalid;
    deqReq[3] <= tagged Invalid;
  endrule

  method Bool notFull = count != depth;

  method Bool notEmpty = count != 0;

  method Action enq(StoreBufEntry x) if (count != depth);
    enqReq[0] <= tagged Valid x;
  endmethod

  method Action deq if (count != 0);
    deqReq[0] <= tagged Valid True;
  endmethod

  method StoreBufEntry first if (count != 0);
    return data[deqP];
  endmethod

  method StoreForwardResult forward(Addr addr);
    StoreForwardResult ret = StoreForwardResult{data: 0, byteEn: 0};
    Bit#(TLog#(n)) ptr = deqP;

    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      Bit#(TAdd#(TLog#(n), 1)) offset = fromInteger(i);
      if (offset < count) begin
        let e = data[ptr];
        if (coreSameWordAddr(e.addr, addr)) begin
          ret.data = coreApplyByteMask(ret.data, e.data, e.byteEn);
          ret.byteEn = ret.byteEn | e.byteEn;
        end
      end
      ptr = nextPtr(ptr);
    end

    if (enqReq[2] matches tagged Valid .x) begin
      if (coreSameWordAddr(x.addr, addr)) begin
        ret.data = coreApplyByteMask(ret.data, x.data, x.byteEn);
        ret.byteEn = ret.byteEn | x.byteEn;
      end
    end

    return ret;
  endmethod

  method Bool search(Addr addr);
    Bool ret = False;
    Bit#(TLog#(n)) ptr = deqP;

    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      Bit#(TAdd#(TLog#(n), 1)) offset = fromInteger(i);
      if (offset < count) begin
        let e = data[ptr];
        if (coreSameWordAddr(e.addr, addr)) begin
          ret = True;
        end
      end
      ptr = nextPtr(ptr);
    end

    if (enqReq[2] matches tagged Valid .x) begin
      if (coreSameWordAddr(x.addr, addr)) begin
        ret = True;
      end
    end

    return ret;
  endmethod

  method Action clear;
    enqReq[1] <= tagged Invalid;
    deqReq[1] <= tagged Invalid;
    clearReq[0] <= tagged Valid True;
  endmethod
endmodule
