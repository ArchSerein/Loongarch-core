package Idecode;

`include "Autoconf.bsv"
`ifdef CONFIG_VSIM
`define CONFIG_WB_DEBUG
`define CONFIG_WB_DEBUG_INST
`endif
`ifdef CONFIG_FPGA
`define CONFIG_WB_DEBUG
`endif

import Types::*;
import ProcTypes::*;
import Fifo::*;
import Decode::*;
import CoreTypes::*;
import CoreFunc::*;

`include "CsrAddr.bsv"

// Decode Stage: Instruction Decode
// Translates 32-bit instruction word into pipeline control signals (DecodedInst)
// and handles early exception detection (unsupported instructions, system calls).
function Action doDecodeBody(Fifo#(2, F2D) f2dFifo, Fifo#(2, D2R) d2rFifo);
    action
    let fetchPkt = f2dFifo.first();
    Instruction inst = fetchPkt.inst;

    f2dFifo.deq();

    // Decode instruction
    DecodedInst dInst = decode(inst);
    ExcpInfo dExcp = fetchPkt.excp;
    
    // Early exception checking
    if (!dExcp.valid) begin
      if (dInst.iType == Unsupported) dExcp = mkExcp(`ECODE_INE, `ESUBCODE_NONE, fetchPkt.pc);
      else if (dInst.iType == Syscall) begin
        `ifdef CONFIG_BSIM
        Bit#(9) syscallEsubcode = (inst[14:0] == 15'h11) ? 9'h001 : `ESUBCODE_NONE;
        dExcp = mkExcp(`ECODE_SYS, syscallEsubcode, fetchPkt.pc);
        `else
        dExcp = mkExcp(`ECODE_SYS, `ESUBCODE_NONE, fetchPkt.pc);
        `endif
      end
      else if (dInst.iType == Break) dExcp = mkExcp(`ECODE_BRK, `ESUBCODE_NONE, fetchPkt.pc);
    end

    // Send decoded instruction to Register Read stage
    d2rFifo.enq(D2R{
      pc: fetchPkt.pc, 
      predPc: fetchPkt.predPc,
`ifdef CONFIG_DIFFTEST
      inst: inst,
`else
`ifdef CONFIG_WB_DEBUG_INST
      inst: inst,
`endif
`endif
      dInst: dInst, 
      excp: dExcp
    });
    endaction
endfunction

endpackage
