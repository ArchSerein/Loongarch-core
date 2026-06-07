import Types::*;
import Vector::*;
import RegFile::*;
import ProcTypes::*;

typedef 24 HistoryLen;
typedef 60 Threshold;

interface PerceptronPredictor#(numeric type indexSize);
  method Bool predict(Addr pc);
  method Action update(Addr pc, Bool taken);
endinterface

module mkPerceptronPredictor(PerceptronPredictor#(indexSize))
provisos(
  Add#(a__, indexSize, 32)
);
  Reg#(Bit#(HistoryLen)) ghr <- mkReg(0);
  Vector#(TAdd#(HistoryLen, 1), RegFile#(Bit#(indexSize), Int#(8))) weights <-
    replicateM(mkRegFileFull);

  Reg#(Bit#(indexSize)) initIdx <- mkReg(0);
  Reg#(Bool) initialized <- mkReg(False);

  function Bit#(indexSize) getIndex(Addr pc);
    return truncate(pc >> 2);
  endfunction

  function Int#(8) satInc(Int#(8) w);
    return (w == 127) ? w : w + 1;
  endfunction

  function Int#(8) satDec(Int#(8) w);
    return (w == -128) ? w : w - 1;
  endfunction

  function Int#(16) computeSum(Bit#(indexSize) idx, Bit#(HistoryLen) hist);
    Int#(16) sum = extend(weights[0].sub(idx));
    for (Integer i = 0; i < valueOf(HistoryLen); i = i + 1) begin
      Int#(16) w = extend(weights[i + 1].sub(idx));
      sum = (hist[i] == 1'b1) ? (sum + w) : (sum - w);
    end
    return sum;
  endfunction

  rule initWeights (!initialized);
    for (Integer i = 0; i < valueOf(TAdd#(HistoryLen, 1)); i = i + 1) begin
      weights[i].upd(initIdx, 0);
    end
    if (initIdx == maxBound) begin
      initialized <= True;
    end else begin
      initIdx <= initIdx + 1;
    end
  endrule

  method Bool predict(Addr pc) if (initialized);
    let idx = getIndex(pc);
    return computeSum(idx, ghr) >= 0;
  endmethod

  method Action update(Addr pc, Bool taken) if (initialized);
    let idx = getIndex(pc);
    Int#(16) sum = computeSum(idx, ghr);
    Bool predWrong = taken ? (sum < 0) : (sum >= 0);
    Int#(16) absSum = (sum < 0) ? -sum : sum;

    if (predWrong || absSum <= fromInteger(valueOf(Threshold))) begin
      Int#(8) w0 = weights[0].sub(idx);
      weights[0].upd(idx, taken ? satInc(w0) : satDec(w0));

      for (Integer i = 0; i < valueOf(HistoryLen); i = i + 1) begin
        Int#(8) wi = weights[i + 1].sub(idx);
        Bool histTaken = unpack(ghr[i]);
        Bool sameOutcome = histTaken == taken;
        weights[i + 1].upd(idx, sameOutcome ? satInc(wi) : satDec(wi));
      end
    end

    ghr <= {ghr[valueOf(HistoryLen) - 2 : 0], pack(taken)};
  endmethod
endmodule
