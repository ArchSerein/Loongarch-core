import Types::*;
import ProcTypes::*;
import Vector::*;
import OoOTypes::*;

// ============================================================
// Common Data Bus (CDB) — multi-port
// Each completing functional unit (Load, ALU, Mul, Div) owns a
// dedicated port.  Producers drive their own port without
// arbitration; all ports latch concurrently and broadcast in
// parallel on the following cycle.  Consumers (reservation
// stations, PRF) receive a Vector#(4, CDBMessage) and iterate
// over every valid entry.
//
// Port index layout (fixed):
//   0 = Load    (doCollectMemCache)
//   1 = ALU     (doExecALUBranch / doExecALUNonBranch)
//   2 = Mul     (doCollectMul)
//   3 = Div     (doCollectDiv)
// ============================================================

typedef 4 CdbPorts;

interface CDB;
  method Action sendLoad(PIndx tag, Data value);
  method Action sendALU (PIndx tag, Data value);
  method Action sendMul (PIndx tag, Data value);
  method Action sendDiv (PIndx tag, Data value);
  method Vector#(CdbPorts, CDBMessage) msgs;
  method Bool anyValid;
endinterface

module mkCDB(CDB);
  // Per-port request DWires; default to Invalid every cycle.
  Vector#(CdbPorts, Wire#(Maybe#(CDBMessage))) ins <- replicateM(mkDWire(tagged Invalid));

  // Per-port latched messages; valid bit indicates "broadcast this cycle".
  Vector#(CdbPorts, Reg#(CDBMessage)) msgRegs <-
    replicateM(mkReg(CDBMessage{tag: 0, value: 0, valid: False}));

  // Latch every port concurrently at the end of each cycle.
  rule latchBroadcast;
    for (Integer i = 0; i < valueOf(CdbPorts); i = i + 1) begin
      CDBMessage next = CDBMessage{tag: 0, value: 0, valid: False};
      if (ins[i] matches tagged Valid .m) begin
        next = m;
      end
      msgRegs[i] <= next;
    end
  endrule

  method Action sendLoad(PIndx tag, Data value);
    ins[0] <= tagged Valid CDBMessage{tag: tag, value: value, valid: True};
  endmethod

  method Action sendALU(PIndx tag, Data value);
    ins[1] <= tagged Valid CDBMessage{tag: tag, value: value, valid: True};
  endmethod

  method Action sendMul(PIndx tag, Data value);
    ins[2] <= tagged Valid CDBMessage{tag: tag, value: value, valid: True};
  endmethod

  method Action sendDiv(PIndx tag, Data value);
    ins[3] <= tagged Valid CDBMessage{tag: tag, value: value, valid: True};
  endmethod

  method Vector#(CdbPorts, CDBMessage) msgs;
    function CDBMessage readMsg(Reg#(CDBMessage) r) = r;
    return map(readMsg, msgRegs);
  endmethod

  method Bool anyValid;
    function Bool isV(Reg#(CDBMessage) r) = r.valid;
    return any(isV, msgRegs);
  endmethod
endmodule
