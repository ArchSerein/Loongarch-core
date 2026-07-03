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

  method CDBMessage msg;
    // Priority: Load > ALU > Mul > Div
    if (loadIn matches tagged Valid .m) return m;
    else if (aluIn matches tagged Valid .m) return m;
    else if (mulIn matches tagged Valid .m) return m;
    else if (divIn matches tagged Valid .m) return m;
    else return CDBMessage{tag: 0, value: 0, valid: False};
  endmethod

  method Bool valid;
    return isValid(loadIn) || isValid(aluIn) || isValid(mulIn) || isValid(divIn);
  endmethod
endmodule
