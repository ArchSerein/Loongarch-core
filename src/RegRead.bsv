package RegRead;

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
import SFifo::*;
import RFile::*;
import CsrFile::*;
import Scoreboard::*;
import CoreFunc::*;
import CoreTypes::*;

// Hazard Detection Logic
// Checks for data hazards using scoreboards for General Purpose Registers (GPR) and CSRs.
function Bool rrfHasHazard(
    D2R decodePkt, 
    Scoreboard#(8) regSb, 
    SFifo#(8, Maybe#(CsrIndx), Maybe#(CsrIndx)) csrSb
);
    let rInst = decodePkt.dInst;
    Bool isCsrWrite = rrfIsCsrWrite(rInst);
    Maybe#(CsrIndx) targetCsr = rrfTargetCsr(rInst);
    
    // Check CSR hazard
    Bool csrConflict = isValid(targetCsr) && csrSb.search(targetCsr);

    // Search scoreboard for source register hazards
    ScoreboardSearchResult src1Sb = regSb.search1(rInst.src1);
    ScoreboardSearchResult src2Sb = regSb.search2(rInst.src2);

    // Data hazard if an older instruction will write to the source register, 
    // and the value is not yet available for forwarding
    Bool src1Hazard = src1Sb.found && !isValid(src1Sb.data);
    Bool src2Hazard = src2Sb.found && !isValid(src2Sb.data);

    return csrConflict || src1Hazard || src2Hazard;
endfunction

// Register Read Stage
// Reads operands from Register File and CSR File, resolves data hazards, 
// and manages operand forwarding (bypassing).
function Action doRrfBody(
    Fifo#(2, D2R) d2rFifo,
    Fifo#(2, R2E) r2eFifo,
    RFile rf,
    CsrFile csrf,
    Scoreboard#(8) regSb,
    SFifo#(8, Maybe#(CsrIndx), Maybe#(CsrIndx)) csrSb
);
    action
    let decodePkt = d2rFifo.first();
    let rInst = decodePkt.dInst;

    Bool isCsrWrite = rrfIsCsrWrite(rInst);
    Bool updatesLlbctl = (rInst.iType == Ll || rInst.iType == Sc);
    Maybe#(CsrIndx) targetCsr = rrfTargetCsr(rInst);

    // Identify instructions that require pipeline flush
    Bool isTlbSerial = rInst.iType == Tlbrd || rInst.iType == Tlbwr || rInst.iType == Tlbfill || rInst.iType == Invtlb;
    Bool isBarrier = coreIsBarrier(rInst.iType) || rInst.iType == Cacop;
    Bool isNeedFlush = isBarrier || isTlbSerial || isCsrWrite || updatesLlbctl;

    ScoreboardSearchResult src1Sb = regSb.search1(rInst.src1);
    ScoreboardSearchResult src2Sb = regSb.search2(rInst.src2);

    // Read General Purpose Registers
    Data rVal1 = rf.rd1(fromMaybe(?, rInst.src1));
    Data rVal2 = rf.rd2(fromMaybe(?, rInst.src2));

    // Handle zero register (r0) and operand forwarding (bypassing) for source 1
    if (rInst.src1 matches tagged Valid .s1 &&& s1 == 0) begin
      rVal1 = 0;
    end else if (src1Sb.found &&& src1Sb.data matches tagged Valid .fwdData1) begin
      rVal1 = fwdData1;
    end

    // Handle zero register (r0) and operand forwarding (bypassing) for source 2
    if (rInst.src2 matches tagged Valid .s2 &&& s2 == 0) begin
      rVal2 = 0;
    end else if (src2Sb.found &&& src2Sb.data matches tagged Valid .fwdData2) begin
      rVal2 = fwdData2;
    end

    // Read CSR File
    CsrIndx csrIdx = fromMaybe(?, rInst.csr);
    if (rInst.iType == Cpucfg) begin
      csrIdx = truncate(rVal1) + 14'hb0;
    end
    Data csrVal = csrf.rd(csrIdx);

    // Enqueue to Execution stage
    ScoreboardTag sbTag = regSb.enqTag;
    r2eFifo.enq(R2E{
      pc: decodePkt.pc,
      predPc: decodePkt.predPc,
`ifdef CONFIG_DIFFTEST
      inst: decodePkt.inst,
`else
`ifdef CONFIG_WB_DEBUG_INST
      inst: decodePkt.inst,
`endif
`endif
      rVal1: rVal1,
      rVal2: rVal2,
      csrVal: csrVal,
      isNeedFlush: isNeedFlush,
      sbTag: sbTag,
      rInst: rInst,
      excp: decodePkt.excp
    });

    // Update scoreboard with destination register to track inflight instructions
    regSb.insert(rInst.dst);
    csrSb.enq((isCsrWrite || updatesLlbctl) ? targetCsr : tagged Invalid);
    d2rFifo.deq();
    endaction
endfunction

endpackage
