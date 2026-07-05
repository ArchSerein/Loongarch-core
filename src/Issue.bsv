package Issue;

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
import MemTypes::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import Mmu::*;
import Tlb::*;
import Fifo::*;
import Ehr::*;
import Vector::*;
import ICache::*;
import DCache::*;
import Mul::*;
import Div::*;
import CoreTypes::*;
import CoreFunc::*;
import BranchPredictor::*;
import BranchPredTypes::*;
import OoOTypes::*;
import RAT::*;
import FreeList::*;
import ROB::*;
import ResStation::*;
import CDB::*;
import StoreBuf::*;
`ifdef CONFIG_TRACE_PERFORMANCE
import Perf::*;
`endif

`include "CsrAddr.bsv"

function Action doIssueALUBody(
    RSEntry entry,
    Reg#(RSEntry) aluExecEntry,
    ResStation#(16) aluRS,
    Reg#(Bool) aluBusy
);
  action
    aluExecEntry <= entry;
    aluRS.remove(entry.robTag);
    aluBusy <= True;
  endaction
endfunction

function Action doExecALUBody(
    Reg#(RSEntry) aluExecEntry,
    Reg#(Bool) aluBusy,
    CDB cdb,
    ROB rob,
    Reg#(Addr) pcReg,
    ICache iCache,
    TlbArray tlb,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    ResStation#(16) aluRS,
    ResStation#(4) muldivRS,
    ResStation#(16) memRS,
    Reg#(Bool) if2WaitRefill,
    RAT rat,
    FreeList freeList,
    BranchPredictor branchPred
);
  action
    let entry = aluExecEntry;
    aluBusy <= False;

    // Construct DecodedInst for exec function
    DecodedInst dInst = DecodedInst{
      iType: entry.iType,
      aluFunc: entry.aluFunc, muldivFunc: entry.muldivFunc,
      brFunc: entry.brFunc,
      dst: tagged Invalid, src1: tagged Invalid, src2: tagged Invalid,
      csr: tagged Invalid,
      imm: entry.imm, cacheOp: entry.cacheOp, mask: entry.mask
    };

    Data immVal = fromMaybe(0, entry.imm);
    ExecInst eInst = exec(dInst, entry.vj, entry.vk, entry.pc, entry.predPc, 0);

    // Write to CDB
    if (entry.pDst matches tagged Valid .pd) begin
      cdb.sendALU(pd, eInst.data);
    end

    // Update ROB
    rob.update(entry.robTag, RobCompleted);
    rob.updateBranch(entry.robTag, eInst.mispredict, eInst.targetAddr);

    // Branch mispredict recovery
    if (eInst.mispredict) begin
`ifdef CONFIG_TRACE_PERFORMANCE
      if (entry.iType == Br || entry.iType == Jr) begin
        perf_branch_mispredict_tage();
      end else begin
        perf_branch_mispredict_fast();
      end
`endif
      pcReg <= eInst.targetAddr;
      iCache.squash;
      tlb.squashFetchLookup;
      f1f2Fifo.clear;
      f2dFifo.clear;
      d2rnFifo.clear;
      rn2diFifo.clear;
      aluRS.clear;
      muldivRS.clear;
      memRS.clear;
      if2WaitRefill <= False;
      rob.flushAfter(entry.robTag);
      rat.restore(entry.robTag);
      freeList.restore(entry.robTag);

      // Train BPU
      CfiType cfiType = CFI_NONE;
      case (entry.iType)
        Br: cfiType = CFI_COND;
        J:  cfiType = CFI_JAL;
        Jr: cfiType = CFI_JALR;
      endcase
      if (cfiType != CFI_NONE) begin
        branchPred.executeUpdate(entry.pc, eInst.targetAddr, eInst.brTaken, cfiType);
      end
    end
  endaction
endfunction

function Action doIssueMulBody(
    RSEntry entry,
    Mul_ifc mulUnit,
    Reg#(RSEntry) mulExecEntry,
    ResStation#(4) muldivRS,
    Reg#(Bool) mulInFlight
);
  action
    let mdFunc = fromMaybe(?, entry.muldivFunc);
    // MulhWu is unsigned; MulW and MulhW are signed.
    Bool is_signed = (mdFunc == MulW || mdFunc == MulhW);
    mulUnit.start(is_signed, entry.vj, entry.vk);
    mulExecEntry <= entry;
    muldivRS.remove(entry.robTag);
    mulInFlight <= True;
  endaction
endfunction

function Action doIssueDivBody(
    RSEntry entry,
    Div_ifc divUnit,
    Reg#(RSEntry) divExecEntry,
    ResStation#(4) muldivRS,
    Reg#(Bool) divInFlight
);
  action
    let mdFunc = fromMaybe(?, entry.muldivFunc);
    // DivWu/ModWu are unsigned; DivW/ModW are signed.
    Bool is_signed = (mdFunc == DivW || mdFunc == ModW);
    divUnit.start(is_signed, entry.vj, entry.vk);
    divExecEntry <= entry;
    muldivRS.remove(entry.robTag);
    divInFlight <= True;
  endaction
endfunction

function Action doIssueMemBody(
    RSEntry entry,
    Reg#(RSEntry) memExecEntry,
    Reg#(Addr) memVaddr,
    Reg#(Addr) memPaddr,
    Reg#(Bool) memNeedTlb,
    Reg#(MemExecState) memState,
    CsrFile csrf,
    TlbArray tlb,
    ICache iCache,
    ROB rob,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf
);
  action
    Data immVal = fromMaybe(0, entry.imm);
    Addr vaddr = entry.vj + immVal;
    ExcpInfo excp = checkMemHasExcp(entry.mask, vaddr, mkNoExcp);

    if (excp.valid) begin
      rob.updateExcp(entry.robTag, excp);
      rob.update(entry.robTag, RobCompleted);
      memRS.remove(entry.robTag);
    end else if (entry.iType == Ibar) begin
      iCache.invalidate;
      rob.update(entry.robTag, RobCompleted);
      memRS.remove(entry.robTag);
    end else begin
      memExecEntry <= entry;
      memVaddr <= vaddr;
      MmuTranslateType transType = getMmuTranslateType(csrf.crmd);
      if (transType == Translate) begin
        tlb.dataLookupReq(vaddr, csrf.asid);
        memNeedTlb <= True;
        memState <= MemTLBWait;
      end else begin
        memPaddr <= vaddr;
        memNeedTlb <= False;
        memState <= MemTLBWait;
      end
    end
  endaction
endfunction

endpackage
