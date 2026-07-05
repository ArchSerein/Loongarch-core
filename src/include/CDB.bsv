import Types::*;
import ProcTypes::*;
import OoOTypes::*;

// ============================================================
// Common Data Bus (CDB)
// Arbitrates among completing functional units and broadcasts
// {tag, value} to all listeners (RS, PRF, ROB)
// Priority: Load > ALU > Mul > Div
// ============================================================

interface CDB;
  method Action sendLoad(PIndx tag, Data value);
  method Action sendALU(PIndx tag, Data value);
  method Action sendMul(PIndx tag, Data value);
  method Action sendDiv(PIndx tag, Data value);
  method CDBMessage msg;       // arbitrated broadcast (this cycle)
  method Bool valid;           // broadcast valid this cycle
endinterface

module mkCDB(CDB);
  Wire#(Maybe#(CDBMessage)) loadIn <- mkDWire(tagged Invalid);
  Wire#(Maybe#(CDBMessage)) aluIn  <- mkDWire(tagged Invalid);
  Wire#(Maybe#(CDBMessage)) mulIn  <- mkDWire(tagged Invalid);
  Wire#(Maybe#(CDBMessage)) divIn  <- mkDWire(tagged Invalid);
  Reg#(CDBMessage) msgReg <- mkReg(CDBMessage{tag: 0, value: 0, valid: False});
  Reg#(Bool) validReg <- mkReg(False);

  rule latchBroadcast;
    CDBMessage nextMsg = CDBMessage{tag: 0, value: 0, valid: False};
    Bool nextValid = False;
    if (loadIn matches tagged Valid .m) begin
      nextMsg = m;
      nextValid = True;
    end else if (aluIn matches tagged Valid .m) begin
      nextMsg = m;
      nextValid = True;
    end else if (mulIn matches tagged Valid .m) begin
      nextMsg = m;
      nextValid = True;
    end else if (divIn matches tagged Valid .m) begin
      nextMsg = m;
      nextValid = True;
    end
    msgReg <= nextMsg;
    validReg <= nextValid;
  endrule

  method Action sendLoad(PIndx tag, Data value);
    loadIn <= tagged Valid CDBMessage{tag: tag, value: value, valid: True};
  endmethod

  method Action sendALU(PIndx tag, Data value);
    aluIn <= tagged Valid CDBMessage{tag: tag, value: value, valid: True};
  endmethod

  method Action sendMul(PIndx tag, Data value);
    mulIn <= tagged Valid CDBMessage{tag: tag, value: value, valid: True};
  endmethod

  method Action sendDiv(PIndx tag, Data value);
    divIn <= tagged Valid CDBMessage{tag: tag, value: value, valid: True};
  endmethod

  method CDBMessage msg = msgReg;

  method Bool valid = validReg;
endmodule
