import Ehr::*;
import Vector::*;
import Types::*;
import ProcTypes::*;

typedef Bit#(3) ScoreboardTag;

typedef struct {
  Bool          found;
  Maybe#(Data) data;
} ScoreboardSearchResult deriving(Bits, Eq);

typedef struct {
  Maybe#(RIndx) regId;
  Maybe#(Data)  exeData;
  Maybe#(Data)  mem1Data;
  Maybe#(Data)  mem2Data;
} ScoreboardEntry deriving(Bits, Eq);

typedef struct {
  Bit#(TLog#(size)) tag;
  Maybe#(Data)      data;
} ScoreboardUpdate#(numeric type size) deriving(Bits, Eq);

interface Scoreboard#(numeric type size);
  method Bit#(TLog#(size)) enqTag;
  method Action insert(Maybe#(RIndx) r);
  method Action remove;
  method ScoreboardSearchResult search1(Maybe#(RIndx) r);
  method ScoreboardSearchResult search2(Maybe#(RIndx) r);
  method ScoreboardSearchResult search3(Maybe#(RIndx) r);
  method Action updateExe(Bit#(TLog#(size)) tag, Maybe#(Data) data);
  method Action updateMem1(Bit#(TLog#(size)) tag, Maybe#(Data) data);
  method Action updateMem2(Bit#(TLog#(size)) tag, Maybe#(Data) data);
  method Action redirect(Bit#(TLog#(size)) tag);
  method Action clear;
endinterface

function Maybe#(RIndx) normalizeScoreboardReg(Maybe#(RIndx) r);
  if (r matches tagged Valid .rv &&& rv == 0) begin
    return tagged Invalid;
  end else begin
    return r;
  end
endfunction

function Bool isFound(Maybe#(RIndx) x, Maybe#(RIndx) k);
  let nx = normalizeScoreboardReg(x);
  let nk = normalizeScoreboardReg(k);
  if (nx matches tagged Valid .xv &&& nk matches tagged Valid .kv &&& kv ==
    xv) begin
    return True;
  end else begin
    return False;
  end
endfunction

function ScoreboardEntry newScoreboardEntry(Maybe#(RIndx) r);
  return ScoreboardEntry{
    regId: normalizeScoreboardReg(r),
    exeData: tagged Invalid,
    mem1Data: tagged Invalid,
    mem2Data: tagged Invalid
  };
endfunction

module mkScoreboard(Scoreboard#(size));
  Vector#(size, Reg#(ScoreboardEntry)) entries <- replicateM(mkRegU);
  Reg#(Bit#(TLog#(size))) enqP <- mkReg(0);
  Reg#(Bit#(TLog#(size))) deqP <- mkReg(0);
  Reg#(Bool) empty <- mkReg(True);
  Reg#(Bool) full <- mkReg(False);
  Bit#(TLog#(size)) maxIndex = fromInteger(valueOf(size) - 1);

  Wire#(Maybe#(ScoreboardEntry)) enqReq <- mkDWire(tagged Invalid);
  Wire#(Bool) deqReq <- mkDWire(False);
  Wire#(Bool) clearReq <- mkDWire(False);
  Wire#(Maybe#(ScoreboardUpdate#(size))) exeUpdate <- mkDWire(tagged Invalid);
  Wire#(Maybe#(ScoreboardUpdate#(size))) mem1Update <- mkDWire(tagged Invalid);
  Wire#(Maybe#(ScoreboardUpdate#(size))) mem2Update <- mkDWire(tagged Invalid);
  Wire#(Maybe#(Bit#(TLog#(size)))) redirectReq <- mkDWire(tagged Invalid);

  function Bit#(TLog#(size)) nextPtr(Bit#(TLog#(size)) curPtr);
    return curPtr == maxIndex ? 0 : curPtr + 1;
  endfunction

  function Bit#(TLog#(size)) ptrOffset(Bit#(TLog#(size)) base,
      Integer offset);
    Bit#(TLog#(size)) ret = base;
    for (Integer i = 0; i < offset; i = i + 1) begin
      ret = nextPtr(ret);
    end
    return ret;
  endfunction

  function Bool entryValid(Bit#(TLog#(size)) idx);
    Bool enqP_lt_deqP = enqP < deqP;
    Bool lt_enqP = idx < enqP;
    Bool gte_deqP = idx >= deqP;
    return full || (!empty &&
      ((enqP_lt_deqP && lt_enqP) ||
       (enqP_lt_deqP && gte_deqP) ||
       (lt_enqP && gte_deqP)));
  endfunction

  function ScoreboardEntry applyPendingUpdate(ScoreboardEntry entry,
      Bit#(TLog#(size)) idx);
    ScoreboardEntry nextEntry = entry;
    if (exeUpdate matches tagged Valid .upd &&& upd.tag == idx) begin
      nextEntry.exeData = upd.data;
      nextEntry.mem1Data = tagged Invalid;
      nextEntry.mem2Data = tagged Invalid;
    end
    if (mem1Update matches tagged Valid .upd &&& upd.tag == idx) begin
      nextEntry.exeData = tagged Invalid;
      nextEntry.mem1Data = upd.data;
      nextEntry.mem2Data = tagged Invalid;
    end
    if (mem2Update matches tagged Valid .upd &&& upd.tag == idx) begin
      nextEntry.exeData = tagged Invalid;
      nextEntry.mem1Data = tagged Invalid;
      nextEntry.mem2Data = upd.data;
    end
    return nextEntry;
  endfunction

  function Maybe#(Data) entryForwardData(ScoreboardEntry entry);
    if (entry.exeData matches tagged Valid .d) begin
      return tagged Valid d;
    end else if (entry.mem1Data matches tagged Valid .d) begin
      return tagged Valid d;
    end else begin
      return entry.mem2Data;
    end
  endfunction

  function ScoreboardSearchResult searchEntry(Maybe#(RIndx) r);
    ScoreboardSearchResult ret = ScoreboardSearchResult{
      found: False,
      data: tagged Invalid
    };
    // Keep search independent of clearReq so rules may use it in guards.
    for (Integer off = 0; off < valueOf(size); off = off + 1) begin
      Bit#(TLog#(size)) idx = ptrOffset(deqP, off);
      ScoreboardEntry entry = applyPendingUpdate(entries[idx], idx);
      if (entryValid(idx) && isFound(entry.regId, r)) begin
        ret = ScoreboardSearchResult{
          found: True,
          data: entryForwardData(entry)
        };
      end
    end
    return ret;
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    if (clearReq) begin
      enqP <= 0;
      deqP <= 0;
      full <= False;
      empty <= True;
    end else begin
      for (Integer i = 0; i < valueOf(size); i = i + 1) begin
        Bit#(TLog#(size)) idx = fromInteger(i);
        ScoreboardEntry nextEntry = applyPendingUpdate(entries[i], idx);
        if (enqReq matches tagged Valid .entry &&& idx == enqP &&& !isValid(redirectReq)) begin
          nextEntry = entry;
        end
        entries[i] <= nextEntry;
      end

      let enqPNext = enqP;
      let deqPNext = deqP;
      if (deqReq) begin
        deqPNext = nextPtr(deqP);
      end
      if (redirectReq matches tagged Valid .tag) begin
        enqPNext = nextPtr(tag);
      end else if (enqReq matches tagged Valid .entry) begin
        enqPNext = nextPtr(enqP);
      end

      enqP <= enqPNext;
      deqP <= deqPNext;

      Bool isEnq = isValid(enqReq);
      Bool isDeq = deqReq;
      Bool nextPtrEq = deqPNext == enqPNext;
      if (redirectReq matches tagged Valid .tag) begin
        empty <= False;
        full <= False;
      end else if (isEnq && !isDeq) begin
        empty <= False;
        full <= nextPtrEq;
      end else if (!isEnq && isDeq) begin
        full <= False;
        empty <= nextPtrEq;
      end
    end
  endrule

  method Bit#(TLog#(size)) enqTag if (!full);
    return enqP;
  endmethod

  method Action insert(Maybe#(RIndx) r) if (!full);
    enqReq <= tagged Valid newScoreboardEntry(r);
  endmethod

  method Action remove if (!empty);
    deqReq <= True;
  endmethod

  method ScoreboardSearchResult search1(Maybe#(RIndx) r);
    return searchEntry(r);
  endmethod

  method ScoreboardSearchResult search2(Maybe#(RIndx) r);
    return searchEntry(r);
  endmethod

  method ScoreboardSearchResult search3(Maybe#(RIndx) r);
    return searchEntry(r);
  endmethod

  method Action updateExe(Bit#(TLog#(size)) tag, Maybe#(Data) data);
    exeUpdate <= tagged Valid ScoreboardUpdate{tag: tag, data: data};
  endmethod

  method Action updateMem1(Bit#(TLog#(size)) tag, Maybe#(Data) data);
    mem1Update <= tagged Valid ScoreboardUpdate{tag: tag, data: data};
  endmethod

  method Action updateMem2(Bit#(TLog#(size)) tag, Maybe#(Data) data);
    mem2Update <= tagged Valid ScoreboardUpdate{tag: tag, data: data};
  endmethod

  method Action redirect(Bit#(TLog#(size)) tag);
    redirectReq <= tagged Valid tag;
  endmethod

  method Action clear;
    clearReq <= True;
  endmethod
endmodule

module mkBypassScoreboard(Scoreboard#(size));
  let scoreboard <- mkScoreboard;
  return scoreboard;
endmodule

module mkPipelineScoreboard(Scoreboard#(size));
  let scoreboard <- mkScoreboard;
  return scoreboard;
endmodule

module mkCFScoreboard(Scoreboard#(size));
  let scoreboard <- mkScoreboard;
  return scoreboard;
endmodule
