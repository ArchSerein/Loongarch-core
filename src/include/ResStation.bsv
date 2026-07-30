import Types::*;
import ProcTypes::*;
import Vector::*;
import OoOTypes::*;

function Bool rsOperandsReady(RSOperandState operands);
  return !isValid(operands.qj) && !isValid(operands.qk);
endfunction

function RSOperandState wakeupOneOperandState(RSOperandState operands, CDBMessage cdb);
  RSOperandState ret = operands;
  if (cdb.valid) begin
    if (ret.qj matches tagged Valid .q &&& q == cdb.tag) begin
      ret.qj = tagged Invalid;
      ret.vj = cdb.value;
    end
    if (ret.qk matches tagged Valid .q &&& q == cdb.tag) begin
      ret.qk = tagged Invalid;
      ret.vk = cdb.value;
    end
  end
  return ret;
endfunction

function RSOperandState wakeupOperandState(
    RSOperandState operands,
    Vector#(4, CDBMessage) cdbs,
    CDBMessage commitCdb
);
  RSOperandState ret = operands;
  for (Integer k = 0; k < 4; k = k + 1) begin
    ret = wakeupOneOperandState(ret, cdbs[k]);
  end
  ret = wakeupOneOperandState(ret, commitCdb);
  return ret;
endfunction

typedef struct {
  Bool valid;
  Bit#(5) age;
  Bit#(4) index;
  AluIssueEntry entry;
} AluRSReadyCandidate;

typedef struct {
  Bool valid;
  Bit#(5) age;
  Bit#(2) index;
  MulDivIssueEntry entry;
} MulDivRSReadyCandidate;

typedef struct {
  Bool valid;
  Bit#(5) age;
  Bit#(4) index;
  MemIssueEntry entry;
} MemRSReadyCandidate;

interface AluRS;
  method Action enq(AluIssueEntry e);
  method Bool notFull;
  method Action wakeup(Vector#(4, CDBMessage) cdbs);
  method Action commitWakeup(CDBMessage cdb);
  method Maybe#(AluIssueEntry) selectOldestReadyForAlu(RobTag headTag, Bool headValid);
  method Action remove(RobToken token);
  method Action flushAfter(RobTag tag, RobTag headTag);
  method Action clear;
endinterface

interface MulDivRS;
  method Action enq(MulDivIssueEntry e);
  method Bool notFull;
  method Action wakeup(Vector#(4, CDBMessage) cdbs);
  method Action commitWakeup(CDBMessage cdb);
  method Maybe#(MulDivIssueEntry) selectOldestReady;
  method Action remove(RobToken token);
  method Action flushAfter(RobTag tag, RobTag headTag);
  method Action clear;
endinterface

interface MemRS;
  method Action enq(MemIssueEntry e);
  method Bool notFull;
  method Action wakeup(Vector#(4, CDBMessage) cdbs);
  method Action commitWakeup(CDBMessage cdb);
  method Maybe#(MemIssueEntry) selectOldestReadyFrom(RobTag headTag);
  method Bool hasOlderStore(RobTag tag, RobTag headTag);
  method Action remove(RobToken token);
  method Action flushAfter(RobTag tag, RobTag headTag);
  method Action clear;
endinterface

module mkAluRS(AluRS);
  Vector#(16, Reg#(AluIssueEntry)) entries <- replicateM(mkRegU);
  Reg#(Bit#(16)) validMask <- mkReg(0);
  Reg#(Bit#(4)) enqP <- mkReg(0);
  Reg#(Bit#(5)) count <- mkReg(0);

  Wire#(Maybe#(AluIssueEntry)) enqReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobToken)) removeReq <- mkDWire(tagged Invalid);
  Wire#(Vector#(4, CDBMessage)) cdbReq <-
    mkDWire(replicate(CDBMessage{tag: 0, value: 0, valid: False}));
  Wire#(CDBMessage) commitCdbReq <- mkDWire(CDBMessage{tag: 0, value: 0, valid: False});
  Wire#(Maybe#(Tuple2#(RobTag, RobTag))) flushReq <- mkDWire(tagged Invalid);
  Wire#(Bool) clearReq <- mkDWire(False);

  function Bit#(4) nextPtr(Bit#(4) ptr);
    return (ptr == 15) ? 0 : ptr + 1;
  endfunction

  function AluRSReadyCandidate chooseOlderReady(
      AluRSReadyCandidate a,
      AluRSReadyCandidate b
  );
    AluRSReadyCandidate ret = a;
    if (!a.valid) begin
      ret = b;
    end else if (b.valid &&
        (b.age < a.age || (b.age == a.age && b.index < a.index))) begin
      ret = b;
    end
    return ret;
  endfunction

  function AluRSReadyCandidate reduceReadyCandidates(
      Vector#(16, AluRSReadyCandidate) stage0
  );
    Vector#(16, AluRSReadyCandidate) stage1 = stage0;
    for (Integer i = 0; i < 8; i = i + 1) begin
      stage1[i] = chooseOlderReady(stage0[2 * i], stage0[2 * i + 1]);
    end

    Vector#(16, AluRSReadyCandidate) stage2 = stage1;
    for (Integer i = 0; i < 4; i = i + 1) begin
      stage2[i] = chooseOlderReady(stage1[2 * i], stage1[2 * i + 1]);
    end

    Vector#(16, AluRSReadyCandidate) stage3 = stage2;
    for (Integer i = 0; i < 2; i = i + 1) begin
      stage3[i] = chooseOlderReady(stage2[2 * i], stage2[2 * i + 1]);
    end

    Vector#(16, AluRSReadyCandidate) stage4 = stage3;
    stage4[0] = chooseOlderReady(stage3[0], stage3[1]);
    return stage4[0];
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    if (clearReq) begin
      validMask <= 0;
      enqP <= 0;
      count <= 0;
    end else if (flushReq matches tagged Valid .req) begin
      RobTag tag = tpl_1(req);
      RobTag headTag = tpl_2(req);
      Bit#(5) flushAge = tag - headTag;
      Bit#(16) keepMask = 0;

      for (Integer i = 0; i < 16; i = i + 1) begin
        AluIssueEntry e = entries[fromInteger(i)];
        Bit#(5) entryAge = e.payload.robTag - headTag;
        Bool keep = validMask[i] == 1 && entryAge <= flushAge;
        keepMask[i] = pack(keep);
      end

      validMask <= keepMask;
      count <= pack(countOnes(keepMask));
    end else begin
      Maybe#(Bit#(4)) removePos = tagged Invalid;
      if (removeReq matches tagged Valid .token) begin
        for (Integer i = 0; i < 16; i = i + 1) begin
          Bit#(4) idx = fromInteger(i);
          if (validMask[idx] == 1 && sameRobToken(entries[idx].payload.token, token)) begin
            removePos = tagged Valid idx;
          end
        end
      end

      Bool hasEnq = isValid(enqReq);
      AluIssueEntry enqEntry = fromMaybe(?, enqReq);
      Maybe#(Bit#(4)) allocPos = tagged Invalid;

      if (hasEnq) begin
        for (Integer i = 0; i < 16; i = i + 1) begin
          Bit#(4) idx = enqP + fromInteger(i);
          if (!isValid(allocPos) && validMask[idx] == 0) begin
            allocPos = tagged Valid idx;
          end
        end
        RSOperandState enqOperands = wakeupOperandState(enqEntry.operands, cdbReq, commitCdbReq);
        enqEntry = AluIssueEntry{payload: enqEntry.payload, operands: enqOperands};
      end

      for (Integer i = 0; i < 16; i = i + 1) begin
        Bit#(4) idx = fromInteger(i);
        if (allocPos matches tagged Valid .ap &&& ap == idx) begin
          entries[idx] <= enqEntry;
        end else begin
          AluIssueEntry e = entries[idx];
          if (validMask[idx] == 1) begin
            RSOperandState nextOperands = wakeupOperandState(e.operands, cdbReq, commitCdbReq);
            if (nextOperands != e.operands) begin
              entries[idx] <= AluIssueEntry{payload: e.payload, operands: nextOperands};
            end
          end
        end
      end

      Bit#(16) nextValidMask = validMask;
      Bit#(4) nextEnqP = enqP;
      Bit#(5) nextCount = count;
      if (allocPos matches tagged Valid .ap) begin
        nextValidMask[ap] = 1;
        nextEnqP = nextPtr(ap);
        nextCount = nextCount + 1;
      end
      if (removePos matches tagged Valid .rp) begin
        nextValidMask[rp] = 0;
        nextCount = nextCount - 1;
      end
      validMask <= nextValidMask;
      enqP <= nextEnqP;
      count <= nextCount;
    end
  endrule

  method Bool notFull = count != 16;

  method Action enq(AluIssueEntry e) if (count != 16);
    enqReq <= tagged Valid e;
  endmethod

  method Maybe#(AluIssueEntry) selectOldestReadyForAlu(RobTag headTag, Bool headValid);
    Maybe#(AluIssueEntry) headBranch = tagged Invalid;

    for (Integer i = 0; i < 16; i = i + 1) begin
      AluIssueEntry e = entries[fromInteger(i)];
      if (validMask[i] == 1 && isBranch(e.payload.iType) && headValid &&
          e.payload.robTag == headTag && rsOperandsReady(e.operands)) begin
        headBranch = tagged Valid e;
      end
    end

    Vector#(16, AluRSReadyCandidate) candidates = newVector;
    for (Integer i = 0; i < 16; i = i + 1) begin
      Bit#(4) idx = fromInteger(i);
      AluIssueEntry e = entries[idx];
      candidates[i] = AluRSReadyCandidate{
        valid: validMask[i] == 1 && !isBranch(e.payload.iType) && rsOperandsReady(e.operands),
        age: e.payload.robTag - headTag,
        index: idx,
        entry: e
      };
    end

    AluRSReadyCandidate winner = reduceReadyCandidates(candidates);
    Maybe#(AluIssueEntry) nonBranch = winner.valid ? tagged Valid winner.entry : tagged Invalid;
    return isValid(headBranch) ? headBranch : nonBranch;
  endmethod

  method Action wakeup(Vector#(4, CDBMessage) cdbs);
    cdbReq <= cdbs;
  endmethod

  method Action commitWakeup(CDBMessage cdb);
    commitCdbReq <= cdb;
  endmethod

  method Action remove(RobToken token);
    removeReq <= tagged Valid token;
  endmethod

  method Action flushAfter(RobTag tag, RobTag headTag);
    flushReq <= tagged Valid tuple2(tag, headTag);
  endmethod

  method Action clear;
    clearReq <= True;
  endmethod
endmodule

module mkMulDivRS(MulDivRS);
  Vector#(4, Reg#(MulDivIssueEntry)) entries <- replicateM(mkRegU);
  Reg#(Bit#(4)) validMask <- mkReg(0);
  Reg#(Bit#(2)) enqP <- mkReg(0);
  Reg#(Bit#(3)) count <- mkReg(0);

  Wire#(Maybe#(MulDivIssueEntry)) enqReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobToken)) removeReq <- mkDWire(tagged Invalid);
  Wire#(Vector#(4, CDBMessage)) cdbReq <-
    mkDWire(replicate(CDBMessage{tag: 0, value: 0, valid: False}));
  Wire#(CDBMessage) commitCdbReq <- mkDWire(CDBMessage{tag: 0, value: 0, valid: False});
  Wire#(Maybe#(Tuple2#(RobTag, RobTag))) flushReq <- mkDWire(tagged Invalid);
  Wire#(Bool) clearReq <- mkDWire(False);

  function Bit#(2) nextPtr(Bit#(2) ptr);
    return (ptr == 3) ? 0 : ptr + 1;
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    if (clearReq) begin
      validMask <= 0;
      enqP <= 0;
      count <= 0;
    end else if (flushReq matches tagged Valid .req) begin
      RobTag tag = tpl_1(req);
      RobTag headTag = tpl_2(req);
      Bit#(5) flushAge = tag - headTag;
      Bit#(4) keepMask = 0;

      for (Integer i = 0; i < 4; i = i + 1) begin
        MulDivIssueEntry e = entries[fromInteger(i)];
        Bit#(5) entryAge = e.payload.robTag - headTag;
        Bool keep = validMask[i] == 1 && entryAge <= flushAge;
        keepMask[i] = pack(keep);
      end

      validMask <= keepMask;
      count <= pack(countOnes(keepMask));
    end else begin
      Maybe#(Bit#(2)) removePos = tagged Invalid;
      if (removeReq matches tagged Valid .token) begin
        for (Integer i = 0; i < 4; i = i + 1) begin
          Bit#(2) idx = fromInteger(i);
          if (validMask[idx] == 1 && sameRobToken(entries[idx].payload.token, token)) begin
            removePos = tagged Valid idx;
          end
        end
      end

      Bool hasEnq = isValid(enqReq);
      MulDivIssueEntry enqEntry = fromMaybe(?, enqReq);
      Maybe#(Bit#(2)) allocPos = tagged Invalid;

      if (hasEnq) begin
        for (Integer i = 0; i < 4; i = i + 1) begin
          Bit#(2) idx = enqP + fromInteger(i);
          if (!isValid(allocPos) && validMask[idx] == 0) begin
            allocPos = tagged Valid idx;
          end
        end
        RSOperandState enqOperands = wakeupOperandState(enqEntry.operands, cdbReq, commitCdbReq);
        enqEntry = MulDivIssueEntry{payload: enqEntry.payload, operands: enqOperands};
      end

      for (Integer i = 0; i < 4; i = i + 1) begin
        Bit#(2) idx = fromInteger(i);
        if (allocPos matches tagged Valid .ap &&& ap == idx) begin
          entries[idx] <= enqEntry;
        end else begin
          MulDivIssueEntry e = entries[idx];
          if (validMask[idx] == 1) begin
            RSOperandState nextOperands = wakeupOperandState(e.operands, cdbReq, commitCdbReq);
            if (nextOperands != e.operands) begin
              entries[idx] <= MulDivIssueEntry{payload: e.payload, operands: nextOperands};
            end
          end
        end
      end

      Bit#(4) nextValidMask = validMask;
      Bit#(2) nextEnqP = enqP;
      Bit#(3) nextCount = count;
      if (allocPos matches tagged Valid .ap) begin
        nextValidMask[ap] = 1;
        nextEnqP = nextPtr(ap);
        nextCount = nextCount + 1;
      end
      if (removePos matches tagged Valid .rp) begin
        nextValidMask[rp] = 0;
        nextCount = nextCount - 1;
      end
      validMask <= nextValidMask;
      enqP <= nextEnqP;
      count <= nextCount;
    end
  endrule

  method Bool notFull = count != 4;

  method Action enq(MulDivIssueEntry e) if (count != 4);
    enqReq <= tagged Valid e;
  endmethod

  method Action wakeup(Vector#(4, CDBMessage) cdbs);
    cdbReq <= cdbs;
  endmethod

  method Action commitWakeup(CDBMessage cdb);
    commitCdbReq <= cdb;
  endmethod

  method Maybe#(MulDivIssueEntry) selectOldestReady;
    Maybe#(MulDivIssueEntry) ret = tagged Invalid;
    Bool found = False;
    for (Integer i = 0; i < 4; i = i + 1) begin
      Bit#(2) idx = enqP + fromInteger(i);
      MulDivIssueEntry e = entries[idx];
      if (!found && validMask[idx] == 1 && rsOperandsReady(e.operands)) begin
        ret = tagged Valid e;
        found = True;
      end
    end
    return ret;
  endmethod

  method Action remove(RobToken token);
    removeReq <= tagged Valid token;
  endmethod

  method Action flushAfter(RobTag tag, RobTag headTag);
    flushReq <= tagged Valid tuple2(tag, headTag);
  endmethod

  method Action clear;
    clearReq <= True;
  endmethod
endmodule

module mkMemRS(MemRS);
  Vector#(16, Reg#(MemIssueEntry)) entries <- replicateM(mkRegU);
  Reg#(Bit#(16)) validMask <- mkReg(0);
  Reg#(Bit#(4)) enqP <- mkReg(0);
  Reg#(Bit#(5)) count <- mkReg(0);

  Wire#(Maybe#(MemIssueEntry)) enqReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobToken)) removeReq <- mkDWire(tagged Invalid);
  Wire#(Vector#(4, CDBMessage)) cdbReq <-
    mkDWire(replicate(CDBMessage{tag: 0, value: 0, valid: False}));
  Wire#(CDBMessage) commitCdbReq <- mkDWire(CDBMessage{tag: 0, value: 0, valid: False});
  Wire#(Maybe#(Tuple2#(RobTag, RobTag))) flushReq <- mkDWire(tagged Invalid);
  Wire#(Bool) clearReq <- mkDWire(False);

  function Bit#(4) nextPtr(Bit#(4) ptr);
    return (ptr == 15) ? 0 : ptr + 1;
  endfunction

  function MemRSReadyCandidate chooseOlderReady(
      MemRSReadyCandidate a,
      MemRSReadyCandidate b
  );
    MemRSReadyCandidate ret = a;
    if (!a.valid) begin
      ret = b;
    end else if (b.valid &&
        (b.age < a.age || (b.age == a.age && b.index < a.index))) begin
      ret = b;
    end
    return ret;
  endfunction

  function MemRSReadyCandidate reduceReadyCandidates(
      Vector#(16, MemRSReadyCandidate) stage0
  );
    Vector#(16, MemRSReadyCandidate) stage1 = stage0;
    for (Integer i = 0; i < 8; i = i + 1) begin
      stage1[i] = chooseOlderReady(stage0[2 * i], stage0[2 * i + 1]);
    end

    Vector#(16, MemRSReadyCandidate) stage2 = stage1;
    for (Integer i = 0; i < 4; i = i + 1) begin
      stage2[i] = chooseOlderReady(stage1[2 * i], stage1[2 * i + 1]);
    end

    Vector#(16, MemRSReadyCandidate) stage3 = stage2;
    for (Integer i = 0; i < 2; i = i + 1) begin
      stage3[i] = chooseOlderReady(stage2[2 * i], stage2[2 * i + 1]);
    end

    Vector#(16, MemRSReadyCandidate) stage4 = stage3;
    stage4[0] = chooseOlderReady(stage3[0], stage3[1]);
    return stage4[0];
  endfunction

  function Bool balancedOr(Bit#(16) stage0);
    Bit#(16) stage1 = stage0;
    for (Integer i = 0; i < 8; i = i + 1) begin
      stage1[i] = stage0[2 * i] | stage0[2 * i + 1];
    end

    Bit#(16) stage2 = stage1;
    for (Integer i = 0; i < 4; i = i + 1) begin
      stage2[i] = stage1[2 * i] | stage1[2 * i + 1];
    end

    Bit#(16) stage3 = stage2;
    for (Integer i = 0; i < 2; i = i + 1) begin
      stage3[i] = stage2[2 * i] | stage2[2 * i + 1];
    end

    Bit#(16) stage4 = stage3;
    stage4[0] = stage3[0] | stage3[1];
    return unpack(stage4[0]);
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    if (clearReq) begin
      validMask <= 0;
      enqP <= 0;
      count <= 0;
    end else if (flushReq matches tagged Valid .req) begin
      RobTag tag = tpl_1(req);
      RobTag headTag = tpl_2(req);
      Bit#(5) flushAge = tag - headTag;
      Bit#(16) keepMask = 0;

      for (Integer i = 0; i < 16; i = i + 1) begin
        MemIssueEntry e = entries[fromInteger(i)];
        Bit#(5) entryAge = e.payload.robTag - headTag;
        Bool keep = validMask[i] == 1 && entryAge <= flushAge;
        keepMask[i] = pack(keep);
      end

      validMask <= keepMask;
      count <= pack(countOnes(keepMask));
    end else begin
      Maybe#(Bit#(4)) removePos = tagged Invalid;
      if (removeReq matches tagged Valid .token) begin
        for (Integer i = 0; i < 16; i = i + 1) begin
          Bit#(4) idx = fromInteger(i);
          if (validMask[idx] == 1 && sameRobToken(entries[idx].payload.token, token)) begin
            removePos = tagged Valid idx;
          end
        end
      end

      Bool hasEnq = isValid(enqReq);
      MemIssueEntry enqEntry = fromMaybe(?, enqReq);
      Maybe#(Bit#(4)) allocPos = tagged Invalid;

      if (hasEnq) begin
        for (Integer i = 0; i < 16; i = i + 1) begin
          Bit#(4) idx = enqP + fromInteger(i);
          if (!isValid(allocPos) && validMask[idx] == 0) begin
            allocPos = tagged Valid idx;
          end
        end
        RSOperandState enqOperands = wakeupOperandState(enqEntry.operands, cdbReq, commitCdbReq);
        enqEntry = MemIssueEntry{payload: enqEntry.payload, operands: enqOperands};
      end

      for (Integer i = 0; i < 16; i = i + 1) begin
        Bit#(4) idx = fromInteger(i);
        if (allocPos matches tagged Valid .ap &&& ap == idx) begin
          entries[idx] <= enqEntry;
        end else begin
          MemIssueEntry e = entries[idx];
          if (validMask[idx] == 1) begin
            RSOperandState nextOperands = wakeupOperandState(e.operands, cdbReq, commitCdbReq);
            if (nextOperands != e.operands) begin
              entries[idx] <= MemIssueEntry{payload: e.payload, operands: nextOperands};
            end
          end
        end
      end

      Bit#(16) nextValidMask = validMask;
      Bit#(4) nextEnqP = enqP;
      Bit#(5) nextCount = count;
      if (allocPos matches tagged Valid .ap) begin
        nextValidMask[ap] = 1;
        nextEnqP = nextPtr(ap);
        nextCount = nextCount + 1;
      end
      if (removePos matches tagged Valid .rp) begin
        nextValidMask[rp] = 0;
        nextCount = nextCount - 1;
      end
      validMask <= nextValidMask;
      enqP <= nextEnqP;
      count <= nextCount;
    end
  endrule

  method Bool notFull = count != 16;

  method Action enq(MemIssueEntry e) if (count != 16);
    enqReq <= tagged Valid e;
  endmethod

  method Action wakeup(Vector#(4, CDBMessage) cdbs);
    cdbReq <= cdbs;
  endmethod

  method Action commitWakeup(CDBMessage cdb);
    commitCdbReq <= cdb;
  endmethod

  method Maybe#(MemIssueEntry) selectOldestReadyFrom(RobTag headTag);
    Vector#(16, MemRSReadyCandidate) candidates = newVector;
    for (Integer i = 0; i < 16; i = i + 1) begin
      Bit#(4) idx = fromInteger(i);
      MemIssueEntry e = entries[idx];
      candidates[i] = MemRSReadyCandidate{
        valid: validMask[i] == 1 && rsOperandsReady(e.operands),
        age: e.payload.robTag - headTag,
        index: idx,
        entry: e
      };
    end

    MemRSReadyCandidate winner = reduceReadyCandidates(candidates);
    return winner.valid ? tagged Valid winner.entry : tagged Invalid;
  endmethod

  method Bool hasOlderStore(RobTag tag, RobTag headTag);
    Bit#(5) tagAge = tag - headTag;
    Bit#(16) olderStoreMask = 0;
    for (Integer i = 0; i < 16; i = i + 1) begin
      MemIssueEntry e = entries[fromInteger(i)];
      Bit#(5) entryAge = e.payload.robTag - headTag;
      olderStoreMask[i] = pack(validMask[i] == 1 && e.payload.isStore &&
        e.payload.robTag != tag && entryAge < tagAge);
    end
    return balancedOr(olderStoreMask);
  endmethod

  method Action remove(RobToken token);
    removeReq <= tagged Valid token;
  endmethod

  method Action flushAfter(RobTag tag, RobTag headTag);
    flushReq <= tagged Valid tuple2(tag, headTag);
  endmethod

  method Action clear;
    clearReq <= True;
  endmethod
endmodule
