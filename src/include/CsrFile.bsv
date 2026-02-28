import Types::*;
import ProcTypes::*;
import Ehr::*;
import ConfigReg::*;
import Fifo::*;

interface CsrFile;
  method Action start;
  method Bool started;
  method Data rd(CsrIndx idx);
  method Action wr(Maybe#(CsrIndx) idx, Data val);
  method ActionValue#(CpuToHostData) cpuToHost;
  method Bool cpuToHostValid;
endinterface

(* synthesize *)
module mkCsrFile#(CoreID id)(CsrFile);
  Reg#(Bool) startReg <- mkReg(False);

  Reg#(Data) numInsts <- mkReg(0);
  Reg#(Data)   cycles <- mkReg(0);
  Data         coreId =  zeroExtend(id);
  Fifo#(2, CpuToHostData) toHostFifo <- mkCFFifo;

  rule count (startReg);
    cycles <= cycles + 1;
  endrule

  method Action start if(!startReg);
    startReg <= True;
    cycles <= 0;
  endmethod

  method Bool started;
    return startReg;
  endmethod

  method Data rd(CsrIndx idx);
    return (case(idx)
            csrCpuid:   coreId;
            csrMtohost: 0;
            default: ?;
        endcase);
  endmethod

  method Action wr(Maybe#(CsrIndx) csrIdx, Data val);
    if(csrIdx matches tagged Valid .idx) begin
      case (idx)
        csrMtohost: begin
          Bit#(16) hi = truncateLSB(val);
          Bit#(16) lo = truncate(val);
          toHostFifo.enq(CpuToHostData {
            c2hType: unpack(truncate(hi)),
            data: lo
          });
        end
      endcase
    end
    numInsts <= numInsts + 1;
  endmethod

  method ActionValue#(CpuToHostData) cpuToHost;
    toHostFifo.deq;
    return toHostFifo.first;
  endmethod

  method Bool cpuToHostValid = toHostFifo.notEmpty;
endmodule
