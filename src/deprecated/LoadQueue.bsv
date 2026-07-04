import Types::*;
import ProcTypes::*;
import Vector::*;
import OoOTypes::*;
import CoreFunc::*;

// ============================================================
// Load Queue: 16-entry tracking for OoO loads
// Tracks load addresses, completion, and replay status
// Used for memory disambiguation and Load-Store conflict detection
// ============================================================

interface LoadQueue;
  method Action enq(LQEntry e);
  method Bool notFull;
  method Action updateAddr(RobTag tag, Addr vaddr);
  method Action markDone(RobTag tag);
  method Action markReplay(RobTag tag);
  method Bool hasConflict(Addr addr);   // check if any active load matches addr
  method Action flushAfter(RobTag tag);
  method Action clear;
endinterface

module mkLoadQueue(LoadQueue);
  Integer lqSize = 16;
  Vector#(16, Reg#(LQEntry)) entries <- replicateM(mkRegU);
  Reg#(Bit#(4)) enqP <- mkReg(0);
  Reg#(Bit#(5)) count <- mkReg(0);

  Wire#(Maybe#(LQEntry)) enqReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(Tuple2#(RobTag, Addr))) addrReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobTag)) doneReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobTag)) replayReq <- mkDWire(tagged Invalid);
  Wire#(Maybe#(RobTag)) flushReq <- mkDWire(tagged Invalid);
  Wire#(Bool) clearReq <- mkDWire(False);

  Bit#(4) maxIndex = fromInteger(lqSize - 1);
  Bit#(5) depth = fromInteger(lqSize);

  function Bit#(4) nextPtr(Bit#(4) ptr);
    return (ptr == maxIndex) ? 0 : ptr + 1;
  endfunction

  (* fire_when_enabled *)
  (* no_implicit_conditions *)
  rule canonicalize;
    if (clearReq) begin
      enqP <= 0;
      count <= 0;
      for (Integer i = 0; i < lqSize; i = i + 1) begin
        entries[fromInteger(i)] <= invalidLQEntry;
      end
    end else if (flushReq matches tagged Valid .tag) begin
      // Find flush position and invalidate younger entries
      Maybe#(Bit#(4)) flushPos = tagged Invalid;
      for (Integer i = 0; i < lqSize; i = i + 1) begin
        Bit#(4) idx = fromInteger(i);
        if (entries[idx].valid && entries[idx].robTag == tag) begin
          flushPos = tagged Valid idx;
        end
      end
      if (flushPos matches tagged Valid .fp) begin
        for (Integer i = 0; i < lqSize; i = i + 1) begin
          Bit#(4) idx = fp + fromInteger(i + 1);
          if (idx != enqP) begin
            entries[idx] <= invalidLQEntry;
          end
        end
        enqP <= fp + 1;
        count <= zeroExtend(fp - enqP) + 1;
      end
    end else begin
      // Normal: process enq, addr update, done, replay
      Bool hasEnq = isValid(enqReq);
      LQEntry enqEntry = fromMaybe(?, enqReq);

      for (Integer i = 0; i < lqSize; i = i + 1) begin
        Bit#(4) idx = fromInteger(i);

        if (hasEnq && enqP == idx) begin
          entries[idx] <= enqEntry;
        end else begin
          LQEntry e = entries[idx];
          if (e.valid) begin
            Addr newVaddr = e.vaddr;
            Bool newDone = e.done;
            Bool newReplay = e.replay;
            Bool modified = False;

            if (addrReq matches tagged Valid .req &&& tpl_1(req) == e.robTag) begin
              newVaddr = tpl_2(req);
              modified = True;
            end
            if (doneReq matches tagged Valid .tag &&& tag == e.robTag) begin
              newDone = True;
              modified = True;
            end
            if (replayReq matches tagged Valid .tag &&& tag == e.robTag) begin
              newReplay = True;
              modified = True;
            end

            if (modified) begin
              entries[idx] <= LQEntry {
                valid: e.valid, robTag: e.robTag, vaddr: newVaddr,
                paddr: e.paddr, done: newDone, replay: newReplay
              };
            end
          end
        end
      end

      Bit#(4) nextEnqP = enqP;
      Bit#(5) nextCount = count;
      if (hasEnq) begin
        nextEnqP = nextPtr(enqP);
        nextCount = nextCount + 1;
      end
      enqP <= nextEnqP;
      count <= nextCount;
    end
  endrule

  method Bool notFull = count != depth;

  method Action enq(LQEntry e) if (count != depth);
    enqReq <= tagged Valid e;
  endmethod

  method Action updateAddr(RobTag tag, Addr vaddr);
    addrReq <= tagged Valid tuple2(tag, vaddr);
  endmethod

  method Action markDone(RobTag tag);
    doneReq <= tagged Valid tag;
  endmethod

  method Action markReplay(RobTag tag);
    replayReq <= tagged Valid tag;
  endmethod

  method Bool hasConflict(Addr addr);
    Bool ret = False;
    for (Integer i = 0; i < lqSize; i = i + 1) begin
      LQEntry e = entries[fromInteger(i)];
      if (e.valid && !e.done && coreSameWordAddr(e.vaddr, addr)) begin
        ret = True;
      end
    end
    return ret;
  endmethod

  method Action flushAfter(RobTag tag);
    flushReq <= tagged Valid tag;
  endmethod

  method Action clear;
    clearReq <= True;
  endmethod
endmodule
