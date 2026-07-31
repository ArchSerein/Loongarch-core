import Types::*;
import ProcTypes::*;
import Vector::*;
import OoOTypes::*;

function Bool rsOperandsReady(RSOperandState operands);
  return !isValid(operands.qj) && !isValid(operands.qk);
endfunction

function Bool cdbMatches(Maybe#(PIndx) q, CDBMessage cdb);
  Bool ret = False;
  if (q matches tagged Valid .p) begin
    ret = cdb.valid && p == cdb.tag;
  end
  return ret;
endfunction

function Bit#(4) cdbHitMask(Maybe#(PIndx) q, Vector#(4, CDBMessage) cdbs);
  Bit#(4) hits = 0;
  for (Integer k = 0; k < 4; k = k + 1) begin
    hits[k] = pack(cdbMatches(q, cdbs[k]));
  end
  return hits;
endfunction

function Data cdbOneHotValue(Vector#(4, CDBMessage) cdbs, Bit#(4) hits);
  Data v0 = (hits[0] == 1'b1) ? cdbs[0].value : 0;
  Data v1 = (hits[1] == 1'b1) ? cdbs[1].value : 0;
  Data v2 = (hits[2] == 1'b1) ? cdbs[2].value : 0;
  Data v3 = (hits[3] == 1'b1) ? cdbs[3].value : 0;
  return (v0 | v1) | (v2 | v3);
endfunction

function Bool wakeupCollision(
    Maybe#(PIndx) q,
    Vector#(4, CDBMessage) cdbs,
    CDBMessage commitCdb
);
  Bit#(4) cdbHits = cdbHitMask(q, cdbs);
  Bit#(3) cdbHitCount = pack(countOnes(cdbHits));
  Bool multiCdb = cdbHitCount > 1;
  Bool commitOverlap = cdbHits != 0 && cdbMatches(q, commitCdb);
  return multiCdb || commitOverlap;
endfunction

function Maybe#(Data) wakeupValueFor(
    Maybe#(PIndx) q,
    Vector#(4, CDBMessage) cdbs,
    CDBMessage commitCdb
);
  Bit#(4) cdbHits = cdbHitMask(q, cdbs);
  Bool hasCdb = cdbHits != 0;
  Bool hasCommit = cdbMatches(q, commitCdb);
  Data cdbValue = cdbOneHotValue(cdbs, cdbHits);
  // Ordinary FU CDB wakeup wins over commit wakeup; BSIM flags overlaps above.
  if (hasCdb) begin
    return tagged Valid cdbValue;
  end else if (hasCommit) begin
    return tagged Valid commitCdb.value;
  end else begin
    return tagged Invalid;
  end
endfunction

function RSOperandState wakeupOperandState(
    RSOperandState operands,
    Vector#(4, CDBMessage) cdbs,
    CDBMessage commitCdb
);
  RSOperandState ret = operands;
  Maybe#(Data) wakeJ = wakeupValueFor(operands.qj, cdbs, commitCdb);
  Maybe#(Data) wakeK = wakeupValueFor(operands.qk, cdbs, commitCdb);

  if (wakeJ matches tagged Valid .v) begin
    ret.qj = tagged Invalid;
    ret.vj = v;
  end
  if (wakeK matches tagged Valid .v) begin
    ret.qk = tagged Invalid;
    ret.vk = v;
  end

  return ret;
endfunction

function Bool operandWakeupCollision(
    RSOperandState operands,
    Vector#(4, CDBMessage) cdbs,
    CDBMessage commitCdb
);
  return wakeupCollision(operands.qj, cdbs, commitCdb) ||
         wakeupCollision(operands.qk, cdbs, commitCdb);
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
  Vector#(16, Reg#(AluRSPayload)) payloads <- replicateM(mkRegU);
  Vector#(16, Reg#(RSOperandState)) operands <- replicateM(mkRegU);
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
        AluRSPayload payload = payloads[fromInteger(i)];
        Bit#(5) entryAge = payload.robTag - headTag;
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
          if (validMask[idx] == 1 && sameRobToken(payloads[idx].token, token)) begin
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
`ifdef CONFIG_BSIM
        if (operandWakeupCollision(enqEntry.operands, cdbReq, commitCdbReq)) begin
          $display("ALU RS WAKEUP ERROR: multiple wakeups hit enqueued operand");
          $finish(1);
        end
`endif
      end

      for (Integer i = 0; i < 16; i = i + 1) begin
        Bit#(4) idx = fromInteger(i);
        if (allocPos matches tagged Valid .ap &&& ap == idx) begin
          payloads[idx] <= enqEntry.payload;
          operands[idx] <= wakeupOperandState(enqEntry.operands, cdbReq, commitCdbReq);
        end else begin
          RSOperandState curOperands = operands[idx];
          if (validMask[idx] == 1) begin
`ifdef CONFIG_BSIM
            if (operandWakeupCollision(curOperands, cdbReq, commitCdbReq)) begin
              $display("ALU RS WAKEUP ERROR: multiple wakeups hit existing operand");
              $finish(1);
            end
`endif
            RSOperandState nextOperands = wakeupOperandState(curOperands, cdbReq, commitCdbReq);
            if (nextOperands != curOperands) begin
              operands[idx] <= nextOperands;
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
      Bit#(4) idx = fromInteger(i);
      AluRSPayload payload = payloads[idx];
      RSOperandState operand = operands[idx];
      if (validMask[i] == 1 && isBranch(payload.iType) && headValid &&
          payload.robTag == headTag && rsOperandsReady(operand)) begin
        headBranch = tagged Valid AluIssueEntry{payload: payload, operands: operand};
      end
    end

    Vector#(16, AluRSReadyCandidate) candidates = newVector;
    for (Integer i = 0; i < 16; i = i + 1) begin
      Bit#(4) idx = fromInteger(i);
      AluRSPayload payload = payloads[idx];
      RSOperandState operand = operands[idx];
      candidates[i] = AluRSReadyCandidate{
        valid: validMask[i] == 1 && !isBranch(payload.iType) && rsOperandsReady(operand),
        age: payload.robTag - headTag,
        index: idx,
        entry: AluIssueEntry{payload: payload, operands: operand}
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
  Vector#(4, Reg#(MulDivRSPayload)) payloads <- replicateM(mkRegU);
  Vector#(4, Reg#(RSOperandState)) operands <- replicateM(mkRegU);
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
        MulDivRSPayload payload = payloads[fromInteger(i)];
        Bit#(5) entryAge = payload.robTag - headTag;
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
          if (validMask[idx] == 1 && sameRobToken(payloads[idx].token, token)) begin
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
`ifdef CONFIG_BSIM
        if (operandWakeupCollision(enqEntry.operands, cdbReq, commitCdbReq)) begin
          $display("MULDIV RS WAKEUP ERROR: multiple wakeups hit enqueued operand");
          $finish(1);
        end
`endif
      end

      for (Integer i = 0; i < 4; i = i + 1) begin
        Bit#(2) idx = fromInteger(i);
        if (allocPos matches tagged Valid .ap &&& ap == idx) begin
          payloads[idx] <= enqEntry.payload;
          operands[idx] <= wakeupOperandState(enqEntry.operands, cdbReq, commitCdbReq);
        end else begin
          RSOperandState curOperands = operands[idx];
          if (validMask[idx] == 1) begin
`ifdef CONFIG_BSIM
            if (operandWakeupCollision(curOperands, cdbReq, commitCdbReq)) begin
              $display("MULDIV RS WAKEUP ERROR: multiple wakeups hit existing operand");
              $finish(1);
            end
`endif
            RSOperandState nextOperands = wakeupOperandState(curOperands, cdbReq, commitCdbReq);
            if (nextOperands != curOperands) begin
              operands[idx] <= nextOperands;
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
      MulDivRSPayload payload = payloads[idx];
      RSOperandState operand = operands[idx];
      if (!found && validMask[idx] == 1 && rsOperandsReady(operand)) begin
        ret = tagged Valid MulDivIssueEntry{payload: payload, operands: operand};
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
  Vector#(16, Reg#(MemRSPayload)) payloads <- replicateM(mkRegU);
  Vector#(16, Reg#(RSOperandState)) operands <- replicateM(mkRegU);
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
        MemRSPayload payload = payloads[fromInteger(i)];
        Bit#(5) entryAge = payload.robTag - headTag;
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
          if (validMask[idx] == 1 && sameRobToken(payloads[idx].token, token)) begin
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
`ifdef CONFIG_BSIM
        if (operandWakeupCollision(enqEntry.operands, cdbReq, commitCdbReq)) begin
          $display("MEM RS WAKEUP ERROR: multiple wakeups hit enqueued operand");
          $finish(1);
        end
`endif
      end

      for (Integer i = 0; i < 16; i = i + 1) begin
        Bit#(4) idx = fromInteger(i);
        if (allocPos matches tagged Valid .ap &&& ap == idx) begin
          payloads[idx] <= enqEntry.payload;
          operands[idx] <= wakeupOperandState(enqEntry.operands, cdbReq, commitCdbReq);
        end else begin
          RSOperandState curOperands = operands[idx];
          if (validMask[idx] == 1) begin
`ifdef CONFIG_BSIM
            if (operandWakeupCollision(curOperands, cdbReq, commitCdbReq)) begin
              $display("MEM RS WAKEUP ERROR: multiple wakeups hit existing operand");
              $finish(1);
            end
`endif
            RSOperandState nextOperands = wakeupOperandState(curOperands, cdbReq, commitCdbReq);
            if (nextOperands != curOperands) begin
              operands[idx] <= nextOperands;
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
      MemRSPayload payload = payloads[idx];
      RSOperandState operand = operands[idx];
      candidates[i] = MemRSReadyCandidate{
        valid: validMask[i] == 1 && rsOperandsReady(operand),
        age: payload.robTag - headTag,
        index: idx,
        entry: MemIssueEntry{payload: payload, operands: operand}
      };
    end

    MemRSReadyCandidate winner = reduceReadyCandidates(candidates);
    return winner.valid ? tagged Valid winner.entry : tagged Invalid;
  endmethod

  method Bool hasOlderStore(RobTag tag, RobTag headTag);
    Bit#(5) tagAge = tag - headTag;
    Bit#(16) olderStoreMask = 0;
    for (Integer i = 0; i < 16; i = i + 1) begin
      MemRSPayload payload = payloads[fromInteger(i)];
      Bit#(5) entryAge = payload.robTag - headTag;
      olderStoreMask[i] = pack(validMask[i] == 1 && payload.isStore &&
        payload.robTag != tag && entryAge < tagAge);
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
