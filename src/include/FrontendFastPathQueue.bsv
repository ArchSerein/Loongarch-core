import Types::*;
import CoreTypes::*;
import BranchPredictor::*;
import Vector::*;

`include "Autoconf.bsv"

`ifndef CONFIG_FRONTEND_FASTPATH_Q_DEPTH
`define CONFIG_FRONTEND_FASTPATH_Q_DEPTH 16
`endif

typedef Bit#(8) FrontendEpoch;

typedef `CONFIG_FRONTEND_FASTPATH_Q_DEPTH FrontendFastPathQDepth;
typedef TLog#(FrontendFastPathQDepth) FastPathQIdxSz;
typedef TAdd#(FastPathQIdxSz, 1) FastPathQSeqSz;

typedef Bit#(FastPathQIdxSz) FastPathQIdx;
typedef Bit#(FastPathQSeqSz) FastPathQSeq;

typedef struct {
  Addr             pc;
  Addr             fastPredPc;
  Addr             selectedPredPc;
  Data             crmd;
  Data             asid;
  Data             dmw0;
  Data             dmw1;
  MmuTranslateType transType;
  FrontendEpoch    epoch;
} FastPathQEntry deriving(Bits, Eq);

typedef struct {
  FastPathQEntry entry;
  Addr           nextPc;
} FetchInflight deriving(Bits, Eq);

interface FastPathQueue;
  method Bool notFull;
  method Bool notEmpty;
  method Bool hasUnverified;
  method Bool fetchUseAccurate;

  method FastPathQSeq deqSeqValue;
  method FastPathQSeq accSeqValue;
  method FastPathQSeq enqSeqValue;

  method FastPathQEntry first;
  method FastPathQEntry accFirst;

  method Action enqFast(FastPathQEntry entry);
  method Action deqFetch(Bool advanceAcc);
  method Action confirmAcc(Addr selectedPredPc);
  method Action truncateAfterAcc(Addr selectedPredPc);
  method Action clear;
endinterface

module mkFastPathQueue(FastPathQueue);
  Vector#(FrontendFastPathQDepth, Reg#(FastPathQEntry)) entries <- replicateM(mkRegU);

  Reg#(FastPathQSeq) deqSeq <- mkReg(0);
  Reg#(FastPathQSeq) accSeq <- mkReg(0);
  Reg#(FastPathQSeq) enqSeq <- mkReg(0);

  FastPathQSeq depth = fromInteger(valueOf(FrontendFastPathQDepth));

  function FastPathQIdx idxOf(FastPathQSeq pos);
    return truncate(pos);
  endfunction

  method Bool notFull = (enqSeq - deqSeq) != depth;
  method Bool notEmpty = deqSeq != enqSeq;
  method Bool hasUnverified = accSeq != enqSeq;
  method Bool fetchUseAccurate = deqSeq != accSeq;

  method FastPathQSeq deqSeqValue = deqSeq;
  method FastPathQSeq accSeqValue = accSeq;
  method FastPathQSeq enqSeqValue = enqSeq;

  method FastPathQEntry first if (deqSeq != enqSeq);
    return entries[idxOf(deqSeq)];
  endmethod

  method FastPathQEntry accFirst if (accSeq != enqSeq);
    return entries[idxOf(accSeq)];
  endmethod

  method Action enqFast(FastPathQEntry entry) if ((enqSeq - deqSeq) != depth);
    entries[idxOf(enqSeq)] <= entry;
    enqSeq <= enqSeq + 1;
  endmethod

  method Action deqFetch(Bool advanceAcc) if (deqSeq != enqSeq);
    deqSeq <= deqSeq + 1;
    if (advanceAcc && accSeq == deqSeq) begin
      accSeq <= accSeq + 1;
    end
  endmethod

  method Action confirmAcc(Addr selectedPredPc) if (accSeq != enqSeq);
    FastPathQEntry entry = entries[idxOf(accSeq)];
    entry.selectedPredPc = selectedPredPc;
    entries[idxOf(accSeq)] <= entry;
    accSeq <= accSeq + 1;
  endmethod

  method Action truncateAfterAcc(Addr selectedPredPc) if (accSeq != enqSeq);
    FastPathQSeq nextAccSeq = accSeq + 1;
    FastPathQEntry entry = entries[idxOf(accSeq)];
    entry.selectedPredPc = selectedPredPc;
    entries[idxOf(accSeq)] <= entry;
    accSeq <= nextAccSeq;
    enqSeq <= nextAccSeq;
  endmethod

  method Action clear;
    deqSeq <= 0;
    accSeq <= 0;
    enqSeq <= 0;
  endmethod
endmodule

function Action doFrontendRebuild(
    Addr target,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) if2WaitRefill
);
  action
    fastQ.clear;
    fetchInflightValid <= False;
    if2WaitRefill <= False;
    frontendEpoch <= frontendEpoch + 1;
    fastGenPc <= target;
  endaction
endfunction

function Action doFrontendRedirect(
    Addr target,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) if2WaitRefill,
    Reg#(Bool) accBusy,
    Reg#(Bool) accReqObsolete,
    BranchPredictor branchPred
);
  action
    fastQ.clear;
    fetchInflightValid <= False;
    if2WaitRefill <= False;
    accBusy <= False;
    accReqObsolete <= False;
    frontendEpoch <= frontendEpoch + 1;
    fastGenPc <= target;
    branchPred.cancelAccurate;
  endaction
endfunction
