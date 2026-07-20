import Types::*;
import Vector::*;
import CoreFunc::*;
import Ehr::*;
import OoOTypes::*;

// ============================================================
// Unified Store Buffer / Store Queue (SQ)
// Tracks speculative, committed, and issued stores in one FIFO.
// ============================================================

interface StoreBuf#(numeric type n);
  method Bool notFull;
  method Bool notEmpty;
  method Bool hasPendingDrain;
  method Bool firstIssuedUncache;
  method Action enqSpeculative(StoreBufEntry x);
  method Action commit(RobToken owner);
  method Action markIssued(RobToken owner);
  method Action complete(RobToken owner);
  method Action deq;
  method StoreBufEntry first;
  method Maybe#(StoreBufEntry) lookupEntry(RobToken owner);
  method StoreForwardResult forwardForLoad(RobToken loadToken, RobTag headTag, Addr paddr);
  method Bool search(Addr paddr);
  method Action flushAfter(RobToken token, RobTag headTag);
  method Action clearSpeculative;
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

  Wire#(Maybe#(StoreBufEntry)) enqReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobToken)) commitReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobToken)) markIssuedReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobToken)) completeReq <- mkDWire(tagged Invalid);
  Wire#(Bool) deqReq <- mkDWire(False);
  Wire#(Maybe#(Tuple2#(RobToken, RobTag))) flushReq <- mkDWire(tagged Invalid);
  Wire#(Bool) clearSpecReq <- mkDWire(False);
  Wire#(Bool) clearReq <- mkDWire(False);

  Bit#(TLog#(n)) maxIndex = fromInteger(valueOf(n) - 1);
  Bit#(TAdd#(TLog#(n), 1)) depth = fromInteger(valueOf(n));

  function Bit#(TLog#(n)) nextPtr(Bit#(TLog#(n)) ptr);
    return (ptr == maxIndex) ? 0 : ptr + 1;
  endfunction

  function Bit#(TLog#(n)) advancePtr(Bit#(TLog#(n)) ptr, Bit#(TAdd#(TLog#(n), 1)) steps);
    Bit#(TLog#(n)) ret = ptr;
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      if (fromInteger(i) < steps) begin
        ret = nextPtr(ret);
      end
    end
    return ret;
  endfunction

  function StoreBufEntry withState(StoreBufEntry e, StoreState state);
    return StoreBufEntry{
      owner: e.owner, state: state,
      vaddr: e.vaddr, paddr: e.paddr, useCache: e.useCache,
      data: e.data, byteEn: e.byteEn
    };
  endfunction

  function Bool flushStore(RobToken owner, StoreState state, RobToken branchToken, RobTag headTag);
    return state == StoreSpeculative &&
      (owner.epoch != branchToken.epoch || robTokenYoungerThan(owner, branchToken, headTag));
  endfunction

  function Bool completeFirst(RobToken owner);
    let e = data[deqP];
    return count != 0 && sameRobToken(e.owner, owner) && e.state == StoreIssued;
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    if (clearReq) begin
      enqP <= 0;
      deqP <= 0;
      count <= 0;
    end else if (flushReq matches tagged Valid .req) begin
      RobToken branchToken = tpl_1(req);
      RobTag headTag = tpl_2(req);
      Bool doComplete = False;
      if (completeReq matches tagged Valid .owner) begin
        doComplete = completeFirst(owner);
      end
      Bit#(TLog#(n)) startP = doComplete ? nextPtr(deqP) : deqP;
      Bit#(TAdd#(TLog#(n), 1)) scanCount = doComplete ? count - 1 : count;
      Bit#(TAdd#(TLog#(n), 1)) keepCount = 0;
      Bool foundFlush = False;
      Bit#(TLog#(n)) ptr = startP;

      for (Integer i = 0; i < valueOf(n); i = i + 1) begin
        Bit#(TAdd#(TLog#(n), 1)) offset = fromInteger(i);
        if (offset < scanCount && !foundFlush) begin
          let e = data[ptr];
          if (flushStore(e.owner, e.state, branchToken, headTag)) begin
            foundFlush = True;
          end else begin
            keepCount = keepCount + 1;
          end
        end
        ptr = nextPtr(ptr);
      end

      deqP <= startP;
      count <= keepCount;
      enqP <= advancePtr(startP, keepCount);
    end else if (clearSpecReq) begin
      Bool doComplete = False;
      if (completeReq matches tagged Valid .owner) begin
        doComplete = completeFirst(owner);
      end
      Bit#(TLog#(n)) startP = doComplete ? nextPtr(deqP) : deqP;
      Bit#(TAdd#(TLog#(n), 1)) scanCount = doComplete ? count - 1 : count;
      Bit#(TAdd#(TLog#(n), 1)) keepCount = 0;
      Bool foundSpec = False;
      Bit#(TLog#(n)) ptr = startP;

      for (Integer i = 0; i < valueOf(n); i = i + 1) begin
        Bit#(TAdd#(TLog#(n), 1)) offset = fromInteger(i);
        if (offset < scanCount && !foundSpec) begin
          let e = data[ptr];
          if (e.state == StoreSpeculative) begin
            foundSpec = True;
          end else begin
            keepCount = keepCount + 1;
          end
        end
        ptr = nextPtr(ptr);
      end

      deqP <= startP;
      count <= keepCount;
      enqP <= advancePtr(startP, keepCount);
    end else begin
      Bool doDeq = deqReq && count != 0;
      if (completeReq matches tagged Valid .owner) begin
        if (completeFirst(owner)) begin
          doDeq = True;
        end
      end

      Bit#(TLog#(n)) nextDeqP = doDeq ? nextPtr(deqP) : deqP;
      Bit#(TAdd#(TLog#(n), 1)) afterDeqCount = doDeq ? count - 1 : count;
      Bool doEnq = False;
      StoreBufEntry enqEntry = ?;
      if (enqReq matches tagged Valid .x &&& afterDeqCount != depth) begin
        doEnq = True;
        enqEntry = x;
      end

      for (Integer i = 0; i < valueOf(n); i = i + 1) begin
        Bit#(TLog#(n)) idx = fromInteger(i);
        StoreBufEntry cur = data[idx];
        StoreBufEntry nextEntry = cur;
        Bool doWrite = False;
        Bool droppedHead = doDeq && idx == deqP;

        if (doEnq && idx == enqP) begin
          nextEntry = enqEntry;
          doWrite = True;
        end else if (!droppedHead) begin
          if (commitReq matches tagged Valid .owner &&& sameRobToken(cur.owner, owner) &&
              cur.state == StoreSpeculative) begin
            nextEntry = withState(cur, StoreCommitted);
            doWrite = True;
          end else if (markIssuedReq matches tagged Valid .owner &&& sameRobToken(cur.owner, owner) &&
              cur.state == StoreCommitted) begin
            nextEntry = withState(cur, StoreIssued);
            doWrite = True;
          end
        end

        if (doWrite) begin
          data[idx] <= nextEntry;
        end
      end

      deqP <= nextDeqP;
      enqP <= doEnq ? nextPtr(enqP) : enqP;
      count <= doEnq ? afterDeqCount + 1 : afterDeqCount;
    end
  endrule

  method Bool notFull = count != depth;

  method Bool notEmpty = count != 0;

  method Bool hasPendingDrain;
    Bool ret = False;
    Bit#(TLog#(n)) ptr = deqP;
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      Bit#(TAdd#(TLog#(n), 1)) offset = fromInteger(i);
      if (offset < count) begin
        let e = data[ptr];
        if (e.state == StoreCommitted || e.state == StoreIssued) begin
          ret = True;
        end
      end
      ptr = nextPtr(ptr);
    end
    return ret;
  endmethod

  method Bool firstIssuedUncache;
    let e = data[deqP];
    return count != 0 && e.state == StoreIssued && !e.useCache;
  endmethod

  method Action enqSpeculative(StoreBufEntry x) if (count != depth);
    enqReq <= tagged Valid withState(x, StoreSpeculative);
  endmethod

  method Action commit(RobToken owner);
    commitReq <= tagged Valid owner;
  endmethod

  method Action markIssued(RobToken owner);
    markIssuedReq <= tagged Valid owner;
  endmethod

  method Action complete(RobToken owner);
    completeReq <= tagged Valid owner;
  endmethod

  method Action deq;
    deqReq <= True;
  endmethod

  method StoreBufEntry first if (count != 0);
    return data[deqP];
  endmethod

  method Maybe#(StoreBufEntry) lookupEntry(RobToken owner);
    Maybe#(StoreBufEntry) ret = tagged Invalid;
    Bit#(TLog#(n)) ptr = deqP;
    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      Bit#(TAdd#(TLog#(n), 1)) offset = fromInteger(i);
      if (offset < count) begin
        let e = data[ptr];
        if (sameRobToken(e.owner, owner)) begin
          ret = tagged Valid e;
        end
      end
      ptr = nextPtr(ptr);
    end
    if (enqReq matches tagged Valid .x &&& sameRobToken(x.owner, owner)) begin
      ret = tagged Valid x;
    end
    return ret;
  endmethod

  method StoreForwardResult forwardForLoad(RobToken loadToken, RobTag headTag, Addr paddr);
    StoreForwardResult ret = StoreForwardResult{data: 0, byteEn: 0};
    Bit#(TLog#(n)) ptr = deqP;

    for (Integer i = 0; i < valueOf(n); i = i + 1) begin
      Bit#(TAdd#(TLog#(n), 1)) offset = fromInteger(i);
      if (offset < count) begin
        let e = data[ptr];
        Bool older = robTokenOlderThan(e.owner, loadToken, headTag);
        if (older && coreSameWordAddr(e.paddr, paddr)) begin
          ret.data = coreApplyByteMask(ret.data, e.data, truncate(e.byteEn));
          ret.byteEn = ret.byteEn | e.byteEn;
        end
      end
      ptr = nextPtr(ptr);
    end

    if (enqReq matches tagged Valid .x) begin
      Bool older = robTokenOlderThan(x.owner, loadToken, headTag);
      if (older && coreSameWordAddr(x.paddr, paddr)) begin
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

    if (enqReq matches tagged Valid .x) begin
      if (coreSameWordAddr(x.paddr, paddr)) begin
        ret = True;
      end
    end

    return ret;
  endmethod

  method Action flushAfter(RobToken token, RobTag headTag);
    flushReq <= tagged Valid tuple2(token, headTag);
  endmethod

  method Action clearSpeculative;
    clearSpecReq <= True;
  endmethod

  method Action clear;
    clearReq <= True;
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
