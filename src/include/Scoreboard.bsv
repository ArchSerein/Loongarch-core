import Vector::*;
import Types::*;
import ProcTypes::*;

typedef Bit#(3) ScoreboardTag;

typedef struct {
  Bool          found;
  Maybe#(Data) data;
} ScoreboardSearchResult deriving(Bits, Eq);

typedef struct {
  Bool                busy;
  Bit#(TLog#(size))  tag;
} RegStatus#(numeric type size) deriving(Bits, Eq);

typedef struct {
  Maybe#(RIndx) regId;
} ScoreboardInsert deriving(Bits, Eq);

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

module mkScoreboard(Scoreboard#(size));
  Vector#(32, Reg#(RegStatus#(size))) regStatus <- replicateM(mkReg(RegStatus{
    busy: False,
    tag: 0
  }));
  Vector#(size, Reg#(Maybe#(RIndx))) tagReg <- replicateM(mkReg(tagged Invalid));
  Vector#(size, Reg#(Maybe#(Data))) tagData <- replicateM(mkReg(tagged Invalid));

  Reg#(Bit#(TLog#(size))) enqP <- mkReg(0);
  Reg#(Bit#(TLog#(size))) deqP <- mkReg(0);
  Reg#(Bool) empty <- mkReg(True);
  Reg#(Bool) full <- mkReg(False);
  Bit#(TLog#(size)) maxIndex = fromInteger(valueOf(size) - 1);

  Wire#(Maybe#(ScoreboardInsert)) enqReq <- mkDWire(tagged Invalid);
  Wire#(Bool) deqReq <- mkDWire(False);
  Wire#(Bool) clearReq <- mkDWire(False);
  Wire#(Maybe#(ScoreboardUpdate#(size))) exeUpdate <- mkDWire(tagged Invalid);
  Wire#(Maybe#(ScoreboardUpdate#(size))) mem1Update <- mkDWire(tagged Invalid);
  Wire#(Maybe#(ScoreboardUpdate#(size))) mem2Update <- mkDWire(tagged Invalid);
  Wire#(Maybe#(Bit#(TLog#(size)))) redirectReq <- mkDWire(tagged Invalid);

  function RegStatus#(size) idleStatus;
    return RegStatus{busy: False, tag: 0};
  endfunction

  function Bit#(TLog#(size)) nextPtr(Bit#(TLog#(size)) curPtr);
    return curPtr == maxIndex ? 0 : curPtr + 1;
  endfunction

  function Maybe#(Data) applyPendingTagData(Bit#(TLog#(size)) tag,
      Maybe#(Data) curData);
    Maybe#(Data) ret = curData;
    if (exeUpdate matches tagged Valid .upd &&& upd.tag == tag) begin
      if (upd.data matches tagged Valid .d) begin
        ret = tagged Valid d;
      end
    end
    if (mem1Update matches tagged Valid .upd &&& upd.tag == tag) begin
      if (upd.data matches tagged Valid .d) begin
        ret = tagged Valid d;
      end
    end
    if (mem2Update matches tagged Valid .upd &&& upd.tag == tag) begin
      if (upd.data matches tagged Valid .d) begin
        ret = tagged Valid d;
      end
    end
    return ret;
  endfunction

  function Vector#(32, RegStatus#(size)) rebuildStatus(
      Vector#(size, Maybe#(RIndx)) regs,
      Bit#(TLog#(size)) firstTag,
      Bit#(TLog#(size)) lastTag);
    Vector#(32, RegStatus#(size)) ret = replicate(idleStatus);
    Bit#(TLog#(size)) tag = firstTag;
    Bool done = False;
    for (Integer i = 0; i < valueOf(size); i = i + 1) begin
      if (!done) begin
        if (regs[tag] matches tagged Valid .rid) begin
          ret[rid] = RegStatus{busy: True, tag: tag};
        end
        done = tag == lastTag;
        tag = nextPtr(tag);
      end
    end
    return ret;
  endfunction

  function ScoreboardSearchResult searchEntry(Maybe#(RIndx) r);
    ScoreboardSearchResult ret = ScoreboardSearchResult{
      found: False,
      data: tagged Invalid
    };
    if (normalizeScoreboardReg(r) matches tagged Valid .rid) begin
      RegStatus#(size) status = regStatus[rid];
      ret = ScoreboardSearchResult{
        found: status.busy,
        data: applyPendingTagData(status.tag, tagData[status.tag])
      };
    end
    return ret;
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    Vector#(32, RegStatus#(size)) nextStatus = readVReg(regStatus);
    Vector#(size, Maybe#(RIndx)) nextTagReg = readVReg(tagReg);
    Vector#(size, Maybe#(Data)) nextTagData = readVReg(tagData);

    if (clearReq) begin
      nextStatus = replicate(idleStatus);
      nextTagReg = replicate(tagged Invalid);
      nextTagData = replicate(tagged Invalid);
      for (Integer i = 0; i < 32; i = i + 1) begin
        regStatus[i] <= nextStatus[i];
      end
      for (Integer i = 0; i < valueOf(size); i = i + 1) begin
        tagReg[i] <= nextTagReg[i];
        tagData[i] <= nextTagData[i];
      end
      enqP <= 0;
      deqP <= 0;
      full <= False;
      empty <= True;
    end else begin
      for (Integer i = 0; i < valueOf(size); i = i + 1) begin
        Bit#(TLog#(size)) tag = fromInteger(i);
        nextTagData[i] = applyPendingTagData(tag, nextTagData[i]);
      end

      let enqPNext = enqP;
      let deqPNext = deqP;

      if (deqReq) begin
        if (tagReg[deqP] matches tagged Valid .rid) begin
          if (nextStatus[rid].busy && nextStatus[rid].tag == deqP) begin
            nextStatus[rid] = idleStatus;
          end
        end
        nextTagReg[deqP] = tagged Invalid;
        nextTagData[deqP] = tagged Invalid;
        deqPNext = nextPtr(deqP);
      end

      if (redirectReq matches tagged Valid .tag) begin
        nextStatus = rebuildStatus(nextTagReg, deqPNext, tag);
        enqPNext = nextPtr(tag);
        for (Integer i = 0; i < valueOf(size); i = i + 1) begin
          Bit#(TLog#(size)) idx = fromInteger(i);
          Bool keep = False;
          Bit#(TLog#(size)) scan = deqPNext;
          Bool done = False;
          for (Integer j = 0; j < valueOf(size); j = j + 1) begin
            if (!done) begin
              keep = keep || idx == scan;
              done = scan == tag;
              scan = nextPtr(scan);
            end
          end
          if (!keep) begin
            nextTagReg[i] = tagged Invalid;
            nextTagData[i] = tagged Invalid;
          end
        end
      end else if (enqReq matches tagged Valid .req) begin
        nextTagReg[enqP] = req.regId;
        nextTagData[enqP] = tagged Invalid;
        if (req.regId matches tagged Valid .rid) begin
          nextStatus[rid] = RegStatus{busy: True, tag: enqP};
        end
        enqPNext = nextPtr(enqP);
      end

      for (Integer i = 0; i < 32; i = i + 1) begin
        regStatus[i] <= nextStatus[i];
      end
      for (Integer i = 0; i < valueOf(size); i = i + 1) begin
        tagReg[i] <= nextTagReg[i];
        tagData[i] <= nextTagData[i];
      end

      enqP <= enqPNext;
      deqP <= deqPNext;

      Bool isEnq = isValid(enqReq) && !isValid(redirectReq);
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
    enqReq <= tagged Valid ScoreboardInsert{regId: normalizeScoreboardReg(r)};
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
