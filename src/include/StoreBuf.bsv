import Types::*;
import Vector::*;
import CoreFunc::*;
import Ehr::*;
import OoOTypes::*;

// ============================================================
// Store Buffer / Store Queue (SQ)
// Migrated from tmp/StoreBuf.bsv with types from OoOTypes
// Provides: byte-level merge, load forwarding, address search
// ============================================================

interface StoreBuf#(numeric type n);
  method Bool notFull;
  method Bool notEmpty;
  method Action enq(StoreBufEntry x);
  method Action deq;
  method StoreBufEntry first;
  method StoreForwardResult forward(Addr paddr);
  method Bool search(Addr paddr);
  method Action clear;
endinterface

interface StoreForwardBuf#(numeric type n);
  method Action enq(StoreBufEntry x);
  method StoreForwardResult forward(Addr paddr);
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
          if (tail.useCache && x.useCache && coreSameWordAddr(tail.paddr, x.paddr)) begin
            data[tailP] <= StoreBufEntry{
              vaddr: tail.vaddr,
              paddr: tail.paddr,
              useCache: tail.useCache,
              data: coreApplyByteMask(tail.data, x.data, truncate(x.byteEn)),
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

  method Action deq;
    deqReq[0] <= tagged Valid True;
  endmethod

  method StoreBufEntry first;
    return data[deqP];
  endmethod

  method StoreForwardResult forward(Addr paddr);
    StoreForwardResult ret = StoreForwardResult{data: 0, byteEn: 0};
    Bit#(TLog#(n)) ptr = deqP;

    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      Bit#(TAdd#(TLog#(n), 1)) offset = fromInteger(i);
      if (offset < count) begin
        let e = data[ptr];
        if (coreSameWordAddr(e.paddr, paddr)) begin
          ret.data = coreApplyByteMask(ret.data, e.data, truncate(e.byteEn));
          ret.byteEn = ret.byteEn | e.byteEn;
        end
      end
      ptr = nextPtr(ptr);
    end

    if (enqReq[2] matches tagged Valid .x) begin
      if (coreSameWordAddr(x.paddr, paddr)) begin
        ret.data = coreApplyByteMask(ret.data, x.data, truncate(x.byteEn));
        ret.byteEn = ret.byteEn | x.byteEn;
      end
    end

    return ret;
  endmethod

  method Bool search(Addr paddr);
    Bool ret = False;
    Bit#(TLog#(n)) ptr = deqP;

    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      Bit#(TAdd#(TLog#(n), 1)) offset = fromInteger(i);
      if (offset < count) begin
        let e = data[ptr];
        if (coreSameWordAddr(e.paddr, paddr)) begin
          ret = True;
        end
      end
      ptr = nextPtr(ptr);
    end

    if (enqReq[2] matches tagged Valid .x) begin
      if (coreSameWordAddr(x.paddr, paddr)) begin
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

module mkStoreForwardBuf(StoreForwardBuf#(n)) provisos (Bits#(StoreBufEntry, entrySz));
  Vector#(n, Reg#(StoreBufEntry)) data <- replicateM(mkRegU);
  Vector#(n, Reg#(Bool)) valid <- replicateM(mkReg(False));
  Reg#(Bit#(TLog#(n))) enqP <- mkReg(0);
  Reg#(Bit#(TAdd#(TLog#(n), 1))) count <- mkReg(0);

  Bit#(TLog#(n)) maxIndex = fromInteger(valueOf(n) - 1);
  Bit#(TAdd#(TLog#(n), 1)) depth = fromInteger(valueOf(n));

  function Bit#(TLog#(n)) nextPtr(Bit#(TLog#(n)) ptr);
    return (ptr == maxIndex) ? 0 : ptr + 1;
  endfunction

  method Action enq(StoreBufEntry x);
    data[enqP] <= x;
    valid[enqP] <= True;
    enqP <= nextPtr(enqP);
    if (count != depth) begin
      count <= count + 1;
    end
  endmethod

  method StoreForwardResult forward(Addr paddr);
    StoreForwardResult ret = StoreForwardResult{data: 0, byteEn: 0};
    Bit#(TLog#(n)) ptr = (count == depth) ? enqP : 0;

    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      Bit#(TAdd#(TLog#(n), 1)) offset = fromInteger(i);
      if (offset < count) begin
        let e = data[ptr];
        if (valid[ptr] && coreSameWordAddr(e.paddr, paddr)) begin
          ret.data = coreApplyByteMask(ret.data, e.data, truncate(e.byteEn));
          ret.byteEn = ret.byteEn | e.byteEn;
        end
      end
      ptr = nextPtr(ptr);
    end

    return ret;
  endmethod

  method Action clear;
    enqP <= 0;
    count <= 0;
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      valid[fromInteger(i)] <= False;
    end
  endmethod
endmodule
