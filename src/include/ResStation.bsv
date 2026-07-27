import Types::*;
import ProcTypes::*;
import Vector::*;
import OoOTypes::*;

typedef struct {
  Bool valid;
  Bit#(5) age;
  Bit#(TLog#(size)) index;
  RSEntry entry;
} RSReadyCandidate#(numeric type size);

// ============================================================
// Reservation Station (parameterized)
// Tomasulo-style: CDB wakeup + oldest-ready selection
// Parameterized by size for ALU(16) / MulDiv(4) / Mem(16)
// ============================================================

interface ResStation#(numeric type size);
  method Action enq(RSEntry e);           // dispatch entry (DI stage)
  method Bool notFull;
  method Action wakeup(Vector#(4, CDBMessage) cdbs);  // CDB broadcast listener (all 4 ports)
  method Action commitWakeup(CDBMessage cdb); // commit-stage (CSR) result wakeup
  method Maybe#(RSEntry) selectOldestReady;  // issue selection
  method Maybe#(RSEntry) selectOldestReadyFrom(RobTag headTag);
  method Maybe#(RSEntry) selectOldestReadyForAlu(RobTag headTag, Bool headValid);
  method Bool hasOlderStore(RobTag tag, RobTag headTag);
  method Action remove(RobToken token);  // remove issued entry
  method Action flushAfter(RobTag tag, RobTag headTag); // invalidate younger entries
  method Action clear;                   // full reset
endinterface

module mkResStation(ResStation#(size))
  provisos(
    Bits#(RSEntry, rsSz),
    Log#(TAdd#(1, size), TAdd#(TLog#(size), 1))
  );

  Vector#(size, Reg#(RSEntry)) entries <- replicateM(mkRegU);
  Reg#(Bit#(size)) validMask <- mkReg(0);
  Reg#(Bit#(TLog#(size))) enqP <- mkReg(0);
  Reg#(Bit#(TAdd#(TLog#(size), 1))) count <- mkReg(0);

  Wire#(Maybe#(RSEntry)) enqReq  <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobToken)) removeReq <- mkDWire(tagged Invalid);
  Wire#(Vector#(4, CDBMessage)) cdbReq <-
    mkDWire(replicate(CDBMessage{tag: 0, value: 0, valid: False}));
  // Commit-stage wakeup: CSR/rdtime results are written to the PRF at commit,
  // not broadcast on the CDB, so they need a separate wakeup path to clear
  // dependent RS entries' qj/qk.
  Wire#(CDBMessage) commitCdbReq <- mkDWire(CDBMessage{tag: 0, value: 0, valid: False});
  Wire#(Maybe#(Tuple2#(RobTag, RobTag))) flushReq <- mkDWire(tagged Invalid);
  Wire#(Bool) clearReq           <- mkDWire(False);

  Bit#(TLog#(size)) maxIndex = fromInteger(valueOf(size) - 1);
  Bit#(TAdd#(TLog#(size), 1)) depth = fromInteger(valueOf(size));

  function Bit#(TLog#(size)) nextPtr(Bit#(TLog#(size)) ptr);
    return (ptr == maxIndex) ? 0 : ptr + 1;
  endfunction

  function RSReadyCandidate#(size) chooseOlderReady(
      RSReadyCandidate#(size) a,
      RSReadyCandidate#(size) b
  );
    RSReadyCandidate#(size) ret = a;
    if (!a.valid) begin
      ret = b;
    end else if (b.valid &&
        (b.age < a.age || (b.age == a.age && b.index < a.index))) begin
      ret = b;
    end
    return ret;
  endfunction

  function RSReadyCandidate#(size) reduceReadyCandidates(
      Vector#(size, RSReadyCandidate#(size)) stage0
  );
    // Current RS instantiations are 4 or 16 entries.  Keeping the stages
    // explicit prevents the ROB-age selector from elaborating as a serial fold.
    Vector#(size, RSReadyCandidate#(size)) stage1 = stage0;
    for (Integer i = 0; i < valueOf(size) / 2; i = i + 1) begin
      stage1[i] = chooseOlderReady(stage0[2 * i], stage0[2 * i + 1]);
    end

    Vector#(size, RSReadyCandidate#(size)) stage2 = stage1;
    for (Integer i = 0; i < valueOf(size) / 4; i = i + 1) begin
      stage2[i] = chooseOlderReady(stage1[2 * i], stage1[2 * i + 1]);
    end

    Vector#(size, RSReadyCandidate#(size)) stage3 = stage2;
    for (Integer i = 0; i < valueOf(size) / 8; i = i + 1) begin
      stage3[i] = chooseOlderReady(stage2[2 * i], stage2[2 * i + 1]);
    end

    Vector#(size, RSReadyCandidate#(size)) stage4 = stage3;
    for (Integer i = 0; i < valueOf(size) / 16; i = i + 1) begin
      stage4[i] = chooseOlderReady(stage3[2 * i], stage3[2 * i + 1]);
    end

    return stage4[0];
  endfunction

  function Bool balancedOr(Bit#(size) stage0);
    Bit#(size) stage1 = stage0;
    for (Integer i = 0; i < valueOf(size) / 2; i = i + 1) begin
      stage1[i] = stage0[2 * i] | stage0[2 * i + 1];
    end

    Bit#(size) stage2 = stage1;
    for (Integer i = 0; i < valueOf(size) / 4; i = i + 1) begin
      stage2[i] = stage1[2 * i] | stage1[2 * i + 1];
    end

    Bit#(size) stage3 = stage2;
    for (Integer i = 0; i < valueOf(size) / 8; i = i + 1) begin
      stage3[i] = stage2[2 * i] | stage2[2 * i + 1];
    end

    Bit#(size) stage4 = stage3;
    for (Integer i = 0; i < valueOf(size) / 16; i = i + 1) begin
      stage4[i] = stage3[2 * i] | stage3[2 * i + 1];
    end

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
      Bit#(size) keepMask = 0;

      // Every comparison is independent; the loop elaborates into parallel
      // per-entry subtract/compare logic and produces the retained-valid mask.
      for (Integer i = 0; i < valueOf(size); i = i + 1) begin
        RSEntry e = entries[fromInteger(i)];
        Bit#(5) entryAge = e.robTag - headTag;
        Bool keep = validMask[i] == 1 && entryAge <= flushAge;
        keepMask[i] = pack(keep);
      end

      validMask <= keepMask;
      count <= pack(countOnes(keepMask));
    end else begin
      // Normal operation: CDB wakeup + enq + remove

      // Find remove position
      Maybe#(Bit#(TLog#(size))) removePos = tagged Invalid;
      if (removeReq matches tagged Valid .token) begin
        for (Integer i = 0; i < valueOf(size); i = i + 1) begin
          Bit#(TLog#(size)) idx = fromInteger(i);
          if (validMask[idx] == 1 && sameRobToken(entries[idx].token, token)) begin
            removePos = tagged Valid idx;
          end
        end
      end

      Bool hasEnq = isValid(enqReq);
      RSEntry enqEntry = fromMaybe(?, enqReq);
      Maybe#(Bit#(TLog#(size))) allocPos = tagged Invalid;

      if (hasEnq) begin
        for (Integer i = 0; i < valueOf(size); i = i + 1) begin
          Bit#(TLog#(size)) idx = enqP + fromInteger(i);
          if (!isValid(allocPos) && validMask[idx] == 0) begin
            allocPos = tagged Valid idx;
          end
        end
      end

      // Simultaneous enqueue + CDB/commit wakeup: apply every valid
      // broadcast in the vector to the freshly dispatched entry.
      if (hasEnq) begin
        for (Integer k = 0; k < 4; k = k + 1) begin
          CDBMessage c = cdbReq[k];
          if (c.valid) begin
            if (enqEntry.qj matches tagged Valid .q &&& q == c.tag) begin
              enqEntry.qj = tagged Invalid;
              enqEntry.vj = c.value;
            end
            if (enqEntry.qk matches tagged Valid .q &&& q == c.tag) begin
              enqEntry.qk = tagged Invalid;
              enqEntry.vk = c.value;
            end
          end
        end
        if (commitCdbReq.valid) begin
          if (enqEntry.qj matches tagged Valid .q &&& q == commitCdbReq.tag) begin
            enqEntry.qj = tagged Invalid;
            enqEntry.vj = commitCdbReq.value;
          end
          if (enqEntry.qk matches tagged Valid .q &&& q == commitCdbReq.tag) begin
            enqEntry.qk = tagged Invalid;
            enqEntry.vk = commitCdbReq.value;
          end
        end
      end

      // Process all entries: one write per entry max
      for (Integer i = 0; i < valueOf(size); i = i + 1) begin
        Bit#(TLog#(size)) idx = fromInteger(i);

        if (allocPos matches tagged Valid .ap &&& ap == idx) begin
          // Enq writes to the first free CAM slot found from enqP.
          entries[idx] <= enqEntry;
        end else begin
          // CDB / commit-stage wakeup: clear dependencies and capture values
          RSEntry e = entries[idx];
          if (validMask[idx] == 1) begin
            Maybe#(PIndx) newQj = e.qj;
            Maybe#(PIndx) newQk = e.qk;
            Data newVj = e.vj;
            Data newVk = e.vk;
            Bool modified = False;
            // CDB broadcasts (all 4 FU ports, concurrently)
            for (Integer k = 0; k < 4; k = k + 1) begin
              CDBMessage c = cdbReq[k];
              if (c.valid) begin
                if (newQj matches tagged Valid .q &&& q == c.tag) begin
                  newQj = tagged Invalid;
                  newVj = c.value;
                  modified = True;
                end
                if (newQk matches tagged Valid .q &&& q == c.tag) begin
                  newQk = tagged Invalid;
                  newVk = c.value;
                  modified = True;
                end
              end
            end
            // Commit-stage broadcast (CSR/rdtime results written at commit)
            if (commitCdbReq.valid) begin
              if (newQj matches tagged Valid .q &&& q == commitCdbReq.tag) begin
                newQj = tagged Invalid;
                newVj = commitCdbReq.value;
                modified = True;
              end
              if (newQk matches tagged Valid .q &&& q == commitCdbReq.tag) begin
                newQk = tagged Invalid;
                newVk = commitCdbReq.value;
                modified = True;
              end
            end
            if (modified) begin
              entries[idx] <= RSEntry {
                valid: True, iType: e.iType, aluFunc: e.aluFunc, muldivFunc: e.muldivFunc,
                brFunc: e.brFunc, qj: newQj, qk: newQk, vj: newVj, vk: newVk,
                pDst: e.pDst, robTag: e.robTag, token: e.token, imm: e.imm, pc: e.pc, predPc: e.predPc,
                mask: e.mask, cacheOp: e.cacheOp, isStore: e.isStore, isLoad: e.isLoad
              };
            end
          end
        end
      end

      // Update validity, pointers, and count
      Bit#(size) nextValidMask = validMask;
      Bit#(TLog#(size)) nextEnqP = enqP;
      Bit#(TAdd#(TLog#(size), 1)) nextCount = count;
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

  method Bool notFull = count != depth;

  method Action enq(RSEntry e) if (count != depth);
    enqReq <= tagged Valid e;
  endmethod

  method Maybe#(RSEntry) selectOldestReadyForAlu(RobTag headTag, Bool headValid);
    Maybe#(RSEntry) headBranch = tagged Invalid;

    for (Integer i = 0; i < valueOf(size); i = i + 1) begin
      RSEntry e = entries[fromInteger(i)];
      if (validMask[i] == 1 && isBranch(e.iType) && headValid && e.robTag == headTag &&
          !isValid(e.qj) && !isValid(e.qk)) begin
        headBranch = tagged Valid e;
      end
    end

    Vector#(size, RSReadyCandidate#(size)) candidates = newVector;
    for (Integer i = 0; i < valueOf(size); i = i + 1) begin
      Bit#(TLog#(size)) idx = fromInteger(i);
      RSEntry e = entries[idx];
      candidates[i] = RSReadyCandidate {
        valid: validMask[i] == 1 && !isBranch(e.iType) && !isValid(e.qj) && !isValid(e.qk),
        age: e.robTag - headTag,
        index: idx,
        entry: e
      };
    end

    RSReadyCandidate#(size) winner = reduceReadyCandidates(candidates);
    Maybe#(RSEntry) nonBranch = winner.valid ? tagged Valid winner.entry : tagged Invalid;
    return isValid(headBranch) ? headBranch : nonBranch;
  endmethod

  method Action wakeup(Vector#(4, CDBMessage) cdbs);
    cdbReq <= cdbs;
  endmethod

  method Action commitWakeup(CDBMessage cdb);
    commitCdbReq <= cdb;
  endmethod

  method Maybe#(RSEntry) selectOldestReady;
    Maybe#(RSEntry) ret = tagged Invalid;
    Bool found = False;
    // Scan from the allocation hint in circular order
    for (Integer i = 0; i < valueOf(size); i = i + 1) begin
      Bit#(TLog#(size)) idx = enqP + fromInteger(i);
      RSEntry e = entries[idx];
      if (!found && validMask[idx] == 1 && !isValid(e.qj) && !isValid(e.qk)) begin
        ret = tagged Valid e;
        found = True;
      end
    end
    return ret;
  endmethod

  method Maybe#(RSEntry) selectOldestReadyFrom(RobTag headTag);
    Vector#(size, RSReadyCandidate#(size)) candidates = newVector;
    for (Integer i = 0; i < valueOf(size); i = i + 1) begin
      Bit#(TLog#(size)) idx = fromInteger(i);
      RSEntry e = entries[idx];
      candidates[i] = RSReadyCandidate {
        valid: validMask[i] == 1 && !isValid(e.qj) && !isValid(e.qk),
        age: e.robTag - headTag,
        index: idx,
        entry: e
      };
    end

    RSReadyCandidate#(size) winner = reduceReadyCandidates(candidates);
    return winner.valid ? tagged Valid winner.entry : tagged Invalid;
  endmethod

  method Bool hasOlderStore(RobTag tag, RobTag headTag);
    Bit#(5) tagAge = tag - headTag;
    Bit#(size) olderStoreMask = 0;
    for (Integer i = 0; i < valueOf(size); i = i + 1) begin
      RSEntry e = entries[fromInteger(i)];
      Bit#(5) entryAge = e.robTag - headTag;
      olderStoreMask[i] = pack(validMask[i] == 1 && e.isStore && e.robTag != tag && entryAge < tagAge);
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
