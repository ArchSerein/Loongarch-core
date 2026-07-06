import Types::*;
import ProcTypes::*;
import Vector::*;
import OoOTypes::*;

// ============================================================
// Reservation Station (parameterized)
// Tomasulo-style: CDB wakeup + oldest-ready selection
// Parameterized by size for ALU(16) / MulDiv(4) / Mem(16)
// ============================================================

interface ResStation#(numeric type size);
  method Action enq(RSEntry e);           // dispatch entry (DI stage)
  method Bool notFull;
  method Action wakeup(CDBMessage cdb);  // CDB broadcast listener
  method Action commitWakeup(CDBMessage cdb); // commit-stage (CSR) result wakeup
  method Maybe#(RSEntry) selectOldestReady;  // issue selection
  method Maybe#(RSEntry) selectOldestReadyFrom(RobTag headTag);
  method Bool hasOlderStore(RobTag tag, RobTag headTag);
  method Action remove(RobTag tag);      // remove issued entry
  method Action flushAfter(RobTag tag);  // invalidate younger entries
  method Action clear;                   // full reset
endinterface

module mkResStation(ResStation#(size))
  provisos(
    Bits#(RSEntry, rsSz)
  );

  Vector#(size, Reg#(RSEntry)) entries <- replicateM(mkRegU);
  Reg#(Bit#(TLog#(size))) enqP <- mkReg(0);
  Reg#(Bit#(TAdd#(TLog#(size), 1))) count <- mkReg(0);

  Wire#(Maybe#(RSEntry)) enqReq  <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobTag)) removeReq <- mkDWire(tagged Invalid);
  Wire#(CDBMessage) cdbReq       <- mkDWire(CDBMessage{tag: 0, value: 0, valid: False});
  // Commit-stage wakeup: CSR/rdtime results are written to the PRF at commit,
  // not broadcast on the CDB, so they need a separate wakeup path to clear
  // dependent RS entries' qj/qk.
  Wire#(CDBMessage) commitCdbReq <- mkDWire(CDBMessage{tag: 0, value: 0, valid: False});
  Wire#(Maybe#(RobTag)) flushReq <- mkDWire(tagged Invalid);
  Wire#(Bool) clearReq           <- mkDWire(False);

  Bit#(TLog#(size)) maxIndex = fromInteger(valueOf(size) - 1);
  Bit#(TAdd#(TLog#(size), 1)) depth = fromInteger(valueOf(size));

  function Bit#(TLog#(size)) nextPtr(Bit#(TLog#(size)) ptr);
    return (ptr == maxIndex) ? 0 : ptr + 1;
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    if (clearReq) begin
      enqP <= 0;
      count <= 0;
      for (Integer i = 0; i < valueOf(size); i = i + 1) begin
        entries[fromInteger(i)] <= invalidRSEntry;
      end
    end else if (flushReq matches tagged Valid .tag) begin
      // Find the flush point (entry with matching RobTag)
      Maybe#(Bit#(TLog#(size))) flushPos = tagged Invalid;
      for (Integer i = 0; i < valueOf(size); i = i + 1) begin
        Bit#(TLog#(size)) idx = fromInteger(i);
        if (entries[idx].valid && entries[idx].robTag == tag) begin
          flushPos = tagged Valid idx;
        end
      end

      if (flushPos matches tagged Valid .fp) begin
        // Invalidate all entries after fp (circular, up to enqP)
        for (Integer i = 0; i < valueOf(size); i = i + 1) begin
          Bit#(TLog#(size)) idx = fp + fromInteger(i) + 1;
          if (idx != enqP) begin
            entries[idx] <= invalidRSEntry;
          end
        end
        enqP <= fp + 1;
        count <= zeroExtend(fp - enqP) + 1;
      end
    end else begin
      // Normal operation: CDB wakeup + enq + remove

      // Find remove position
      Maybe#(Bit#(TLog#(size))) removePos = tagged Invalid;
      if (removeReq matches tagged Valid .tag) begin
        for (Integer i = 0; i < valueOf(size); i = i + 1) begin
          Bit#(TLog#(size)) idx = fromInteger(i);
          if (entries[idx].valid && entries[idx].robTag == tag) begin
            removePos = tagged Valid idx;
          end
        end
      end

      Bool hasEnq = isValid(enqReq);
      RSEntry enqEntry = fromMaybe(?, enqReq);

      // Process all entries: one write per entry max
      for (Integer i = 0; i < valueOf(size); i = i + 1) begin
        Bit#(TLog#(size)) idx = fromInteger(i);

        if (hasEnq && enqP == idx) begin
          // Enq writes to this entry (highest priority)
          entries[idx] <= enqEntry;
        end else if (removePos matches tagged Valid .rp &&& rp == idx) begin
          // Remove invalidates this entry
          entries[idx] <= invalidRSEntry;
        end else begin
          // CDB / commit-stage wakeup: clear dependencies and capture values
          RSEntry e = entries[idx];
          if (e.valid && (cdbReq.valid || commitCdbReq.valid)) begin
            Maybe#(PIndx) newQj = e.qj;
            Maybe#(PIndx) newQk = e.qk;
            Data newVj = e.vj;
            Data newVk = e.vk;
            Bool modified = False;
            // CDB broadcast (FU writeback)
            if (cdbReq.valid) begin
              if (e.qj matches tagged Valid .q &&& q == cdbReq.tag) begin
                newQj = tagged Invalid;
                newVj = cdbReq.value;
                modified = True;
              end
              if (e.qk matches tagged Valid .q &&& q == cdbReq.tag) begin
                newQk = tagged Invalid;
                newVk = cdbReq.value;
                modified = True;
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
                pDst: e.pDst, robTag: e.robTag, imm: e.imm, pc: e.pc, predPc: e.predPc,
                mask: e.mask, cacheOp: e.cacheOp, isStore: e.isStore, isLoad: e.isLoad
              };
            end
          end
        end
      end

      // Update pointers and count
      Bit#(TLog#(size)) nextEnqP = enqP;
      Bit#(TAdd#(TLog#(size), 1)) nextCount = count;
      if (hasEnq) begin
        nextEnqP = nextPtr(enqP);
        nextCount = nextCount + 1;
      end
      if (isValid(removePos)) begin
        nextCount = nextCount - 1;
      end
      enqP <= nextEnqP;
      count <= nextCount;
    end
  endrule

  method Bool notFull = count != depth;

  method Action enq(RSEntry e) if (count != depth);
    enqReq <= tagged Valid e;
  endmethod

  method Action wakeup(CDBMessage cdb);
    cdbReq <= cdb;
  endmethod

  method Action commitWakeup(CDBMessage cdb);
    commitCdbReq <= cdb;
  endmethod

  method Maybe#(RSEntry) selectOldestReady;
    Maybe#(RSEntry) ret = tagged Invalid;
    Bool found = False;
    // Scan from enqP (oldest) in circular order
    for (Integer i = 0; i < valueOf(size); i = i + 1) begin
      Bit#(TLog#(size)) idx = enqP + fromInteger(i);
      RSEntry e = entries[idx];
      if (!found && e.valid && !isValid(e.qj) && !isValid(e.qk)) begin
        ret = tagged Valid e;
        found = True;
      end
    end
    return ret;
  endmethod

  method Maybe#(RSEntry) selectOldestReadyFrom(RobTag headTag);
    Maybe#(RSEntry) ret = tagged Invalid;
    Bit#(5) bestAge = 0;
    Bool found = False;
    for (Integer i = 0; i < valueOf(size); i = i + 1) begin
      RSEntry e = entries[fromInteger(i)];
      Bit#(5) entryAge = e.robTag - headTag;
      if (e.valid && !isValid(e.qj) && !isValid(e.qk) &&
          (!found || entryAge < bestAge)) begin
        ret = tagged Valid e;
        bestAge = entryAge;
        found = True;
      end
    end
    return ret;
  endmethod

  method Bool hasOlderStore(RobTag tag, RobTag headTag);
    Bool ret = False;
    Bit#(5) tagAge = tag - headTag;
    for (Integer i = 0; i < valueOf(size); i = i + 1) begin
      RSEntry e = entries[fromInteger(i)];
      Bit#(5) entryAge = e.robTag - headTag;
      if (e.valid && e.isStore && e.robTag != tag && entryAge < tagAge) begin
        ret = True;
      end
    end
    return ret;
  endmethod

  method Action remove(RobTag tag);
    removeReq <= tagged Valid tag;
  endmethod

  method Action flushAfter(RobTag tag);
    flushReq <= tagged Valid tag;
  endmethod

  method Action clear;
    clearReq <= True;
  endmethod
endmodule
