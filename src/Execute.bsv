package Execute;

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
import Exec::*;
import CsrFile::*;
import Scoreboard::*;
import Mul::*;
import Div::*;
import ICache::*;
import Tlb::*;
import Btb::*;
import Bht::*;
import CoreFunc::*;
import CoreTypes::*;
`ifdef CONFIG_TRACE_PERFORMANCE
import Perf::*;
`endif

// Execution Stage
// Performs ALU operations, evaluates branches, manages multi-cycle multiplier/divider,
// and detects branch mispredictions to initiate pipeline squashing.
function Action doExecBody(
    Fifo#(2, R2E) r2eFifo,
    Fifo#(2, E2M) e2mFifo,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2R) d2rFifo,
    Reg#(Addr) pcReg_1,
    ICache iCache,
    TlbArray tlb,
    Btb#(6) btb,
    Bht#(8) bht,
    Scoreboard#(8) regSb,
    SFifo#(8, Maybe#(CsrIndx), Maybe#(CsrIndx)) csrSb,
    Reg#(Bool) if2WaitRefill,
    Mul_ifc mulUnit,
    Reg#(Bool) mulInFlight,
    Div_ifc divUnit,
    Reg#(Bool) divInFlight,
    CsrFile csrf
);
    action
    let rrfPkt = r2eFifo.first();

    Bool doNormalExec = True;
    
    // Multi-cycle ALU Operations (Multiplier and Divider)
    // Handle multi-cycle MUL/DIV instructions, waiting for their completion
    // before proceeding with normal execution logic.
    if (!rrfPkt.excp.valid && isValid(rrfPkt.rInst.muldivFunc)) begin
      let mdFunc = fromMaybe(?, rrfPkt.rInst.muldivFunc);
      Bool is_mul = (mdFunc == MulW || mdFunc == MulhW || mdFunc == MulhWu);
      Bool is_div = (mdFunc == DivW || mdFunc == DivWu || mdFunc == ModW || mdFunc == ModWu);
      Bool is_signed = (mdFunc == MulW || mdFunc == MulhW || mdFunc == DivW || mdFunc == ModW);

      if (is_mul) begin
        if (!mulInFlight) begin
          mulUnit.start(is_signed, rrfPkt.rVal1, rrfPkt.rVal2);
          mulInFlight <= True;
          doNormalExec = False; // Stall pipeline until MUL finishes
        end else if (!mulUnit.finish) begin
          doNormalExec = False;
        end else begin
          mulInFlight <= False;
        end
      end else if (is_div) begin
        if (!divInFlight) begin
          divUnit.start(is_signed, rrfPkt.rVal1, rrfPkt.rVal2);
          divInFlight <= True;
          doNormalExec = False; // Stall pipeline until DIV finishes
        end else if (!divUnit.finish) begin
          doNormalExec = False;
        end else begin
          divInFlight <= False;
        end
      end
    end

    if (doNormalExec) begin
      // Normal ALU Execution and Branch Evaluation
      ExecInst eInst = exec(rrfPkt.rInst, rrfPkt.rVal1, rrfPkt.rVal2, rrfPkt.pc, rrfPkt.predPc, rrfPkt.csrVal);
      ExcpInfo eExcp = rrfPkt.excp;

`ifdef CONFIG_TRACE_PERFORMANCE
      if (rrfPkt.rInst.iType == Br) begin
        perf_branch_exec(eInst.mispredict);
      end
`endif

      // Collect results from Multiplier and Divider
      if (isValid(rrfPkt.rInst.muldivFunc)) begin
        let mdFunc = fromMaybe(?, rrfPkt.rInst.muldivFunc);
        case (mdFunc)
          MulW: eInst.data = truncate(mulUnit.result());
          MulhW, MulhWu: eInst.data = truncateLSB(mulUnit.result());
          DivW, DivWu: eInst.data = truncate(divUnit.result());
          ModW, ModWu: eInst.data = truncateLSB(divUnit.result());
        endcase
      end

      // Process Time registers
      if (rrfPkt.rInst.iType == RdTimeL) begin
        eInst.data = truncate(csrf.stableCounterValue);
      end else if (rrfPkt.rInst.iType == RdTimeH) begin
        eInst.data = truncateLSB(csrf.stableCounterValue);
      end

      // Branch Prediction Integration & Misprediction Recovery
      // If a branch is mispredicted, squash all previous pipeline stages, 
      // redirect PC, and update branch prediction structures (BTB, BHT).
      if (eInst.mispredict) begin
        pcReg_1 <= eInst.targetAddr;
        iCache.squash();
        tlb.squashFetchLookup();
        f1f2Fifo.clear();
        f2dFifo.clear();
        d2rFifo.clear();
        r2eFifo.clear();
        regSb.redirect(rrfPkt.sbTag);
        csrSb.redirect(rrfPkt.sbTag);
        if2WaitRefill <= False;
        btb.update(rrfPkt.pc, eInst.targetAddr);
      end
      bht.update(rrfPkt.pc, eInst.brTaken);

      Bool isMemTypeInst = eInst.iType == Ld || eInst.iType == St || eInst.iType == Ll || eInst.iType == Sc;
      Bool isTlbSerial = (eInst.iType == Tlbsrch || eInst.iType == Tlbrd || eInst.iType == Tlbwr || eInst.iType == Tlbfill || eInst.iType == Invtlb);
      
      // Memory Access Exception Check
      if (isMemTypeInst) begin
        eExcp = checkMemHasExcp(rrfPkt.rInst.mask, eInst.addr, eExcp);
      end

      Bit#(5) execCacheOp = fromMaybe(0, eInst.cacheOp);
      Bool dCacheCacop = (eInst.iType == Cacop) && execCacheOp[2:0] != 3'b000;
      Bool iCacheCacop = (eInst.iType == Cacop) && execCacheOp[2:0] == 3'b000;
      Bool dataTlbLookupPending = (isMemTypeInst || dCacheCacop || iCacheCacop) && getMmuTranslateType(csrf.crmd) == Translate;
      
      // Initiate TLB lookup for memory instructions or Cache Operations
      if (dataTlbLookupPending) begin
        tlb.dataLookupReq(eInst.addr, csrf.asid);
      end

      r2eFifo.deq();
      
      // Update scoreboard with ALU result to allow forwarding (bypassing) to dependent instructions
      Maybe#(Data) exeResult = (isValid(eInst.dst) && !isMemTypeInst && !isTlbSerial) ? tagged Valid eInst.data : tagged Invalid;
      regSb.updateExe(rrfPkt.sbTag, exeResult);
      
      // Enqueue to Memory Access stage
      e2mFifo.enq(E2M{
        pc: rrfPkt.pc,
`ifdef CONFIG_DIFFTEST
        inst: rrfPkt.inst,
`else
`ifdef CONFIG_WB_DEBUG_INST
        inst: rrfPkt.inst,
`endif
`endif
        excp: eExcp,
        mask: rrfPkt.rInst.mask,
        isNeedFlush: rrfPkt.isNeedFlush,
        dataTlbLookupPending: dataTlbLookupPending,
        sbTag: rrfPkt.sbTag,
        eInst: tagged Valid eInst
      });
    end
    endaction
endfunction

endpackage
