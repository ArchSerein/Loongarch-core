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
import FrontendFastPathQueue::*;
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
    AluIssueEntry entry,
    Reg#(AluIssueEntry) aluExecEntry,
    AluRS aluRS,
    Reg#(Bool) aluBusy
);
  action
    aluExecEntry <= entry;
    aluRS.remove(entry.payload.token);
    aluBusy <= True;
  endaction
endfunction

function Action doExecALUBody(
    Reg#(AluIssueEntry) aluExecEntry,
    Reg#(Bool) aluBusy,
    CDB cdb,
    ROB rob,
    Reg#(Addr) pcReg,
    ICache iCache,
    DCache dCache,
    TlbArray tlb,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    AluRS aluRS,
    MulDivRS muldivRS,
    MemRS memRS,
    StoreBuf#(16) storeBuf,
    Reg#(MemExecState) memState,
    Reg#(MemIssueEntry) memExecEntry,
    Reg#(Bool) if2WaitRefill,
    RAT rat,
    FreeList freeList,
    BranchPredictor branchPred,
    FastPathQueue fastQ,
    Reg#(Addr) fastGenPc,
    Reg#(FrontendEpoch) frontendEpoch,
    Reg#(Bool) fetchInflightValid,
    Reg#(Bool) accBusy,
    Reg#(Bool) accReqObsolete
);
  action
    let entry = aluExecEntry;
    aluBusy <= False;

    // Construct DecodedInst for exec function
    DecodedInst dInst = DecodedInst{
      iType: entry.payload.iType,
      aluFunc: entry.payload.aluFunc, muldivFunc: tagged Invalid,
      brFunc: entry.payload.brFunc,
      dst: tagged Invalid, src1: tagged Invalid, src2: tagged Invalid,
      csr: tagged Invalid,
      imm: entry.payload.imm, cacheOp: tagged Invalid, mask: tagged Invalid
    };

    Data immVal = fromMaybe(0, entry.payload.imm);
    Data csrVal = 0;
    if (entry.payload.iType == Cpucfg) begin
      CsrIndx cpuCfgAddr = truncate(entry.operands.vj) + 14'h00b0;
      csrVal = cpuCfgValue(cpuCfgAddr);
    end
    ExecInst eInst = exec(dInst, entry.operands.vj, entry.operands.vk, entry.payload.pc, entry.payload.predPc, csrVal);

    // Write to CDB
    if (entry.payload.pDst matches tagged Valid .pd) begin
      cdb.sendALU(pd, eInst.data);
    end

    // Update ROB
    rob.updateALU(entry.payload.token, RobCompleted);
    rob.updateBranch(entry.payload.token, eInst.mispredict, eInst.targetAddr);

    // Train the predictor for every resolved control-flow instruction.
    // Misprediction only controls recovery; correct predictions must still
    // train the BTB and direction counter.
    CfiType cfiType = CFI_NONE;
    case (entry.payload.iType)
      Br: cfiType = CFI_COND;
      J:  cfiType = CFI_JAL;
      Jr: cfiType = CFI_JALR;
    endcase
    if (cfiType != CFI_NONE) begin
      // For a conditional branch, targetAddr is the resolved next PC and is
      // pc+4 when not taken.  The BTB must retain the static taken target.
      Addr bpuTarget = (entry.payload.iType == Br) ? (entry.payload.pc + immVal) : eInst.targetAddr;
      branchPred.executeUpdate(entry.payload.pc, bpuTarget, eInst.brTaken, cfiType);
    end

    // Branch mispredict recovery
    if (eInst.mispredict) begin
`ifdef CONFIG_TRACE_PERFORMANCE
      if (entry.payload.iType == Br || entry.payload.iType == Jr) begin
        perf_branch_mispredict_tage();
      end else begin
        perf_branch_mispredict_fast();
      end
`endif
      pcReg <= eInst.targetAddr;
      iCache.squash;
      tlb.squashFetchLookup;
      Bool memYounger = memState != MemIdle &&
        robTokenYoungerThan(memExecEntry.payload.token, entry.payload.token, rob.headTag);
      if (memYounger) begin
        if (memState == MemCacheWait) begin
          dCache.squash(False);
        end
        if (memState == MemTLBWait) begin
          tlb.squashDataLookup;
        end
        memState <= MemIdle;
      end
      f1f2Fifo.clear;
      f2dFifo.clear;
      d2rnFifo.clear;
      rn2diFifo.clear;
      aluRS.flushAfter(entry.payload.robTag, rob.headTag);
      muldivRS.flushAfter(entry.payload.robTag, rob.headTag);
      memRS.flushAfter(entry.payload.robTag, rob.headTag);
      storeBuf.flushAfter(entry.payload.token, rob.headTag);
      doFrontendRedirect(eInst.targetAddr, fastQ, fastGenPc, frontendEpoch,
        fetchInflightValid, if2WaitRefill, accBusy, accReqObsolete, branchPred);
      rob.flushAfter(entry.payload.robTag);
      rat.restore(entry.payload.robTag);
      freeList.restore(entry.payload.robTag);

    end
  endaction
endfunction

function Action doIssueMulBody(
    MulDivIssueEntry entry,
    Mul_ifc mulUnit,
    Reg#(MulDivIssueEntry) mulExecEntry,
    MulDivRS muldivRS,
    Reg#(Bool) mulInFlight
);
  action
    let mdFunc = fromMaybe(?, entry.payload.muldivFunc);
    // MulhWu is unsigned; MulW and MulhW are signed.
    Bool is_signed = (mdFunc == MulW || mdFunc == MulhW);
    mulUnit.start(is_signed, entry.operands.vj, entry.operands.vk);
    mulExecEntry <= entry;
    muldivRS.remove(entry.payload.token);
    mulInFlight <= True;
  endaction
endfunction

function Action doIssueDivBody(
    MulDivIssueEntry entry,
    Div_ifc divUnit,
    Reg#(MulDivIssueEntry) divExecEntry,
    MulDivRS muldivRS,
    Reg#(Bool) divInFlight
);
  action
    let mdFunc = fromMaybe(?, entry.payload.muldivFunc);
    // DivWu/ModWu are unsigned; DivW/ModW are signed.
    Bool is_signed = (mdFunc == DivW || mdFunc == ModW);
    divUnit.start(is_signed, entry.operands.vj, entry.operands.vk);
    divExecEntry <= entry;
    muldivRS.remove(entry.payload.token);
    divInFlight <= True;
  endaction
endfunction

function Action doIssueMemBody(
    MemIssueEntry entry,
    Reg#(MemIssueEntry) memExecEntry,
    Reg#(Addr) memVaddr,
    Reg#(Addr) memPaddr,
    Reg#(ExcpInfo) memExcpInfo,
    Reg#(Bool) memNeedTlb,
    Reg#(MemExecState) memState,
    CsrFile csrf,
    TlbArray tlb,
    ICache iCache,
    ROB rob,
    MemRS memRS,
    StoreBuf#(16) storeBuf
);
  action
    if (entry.payload.iType == Ibar) begin
      iCache.invalidate;
      memExecEntry <= entry;
      memState <= MemIbarWait;
    end else if (entry.payload.iType == Dbar) begin
      memExecEntry <= entry;
      memVaddr <= 0;
      memPaddr <= 0;
      memNeedTlb <= False;
      memState <= MemTLBWait;
    end else begin
      Data immVal = fromMaybe(0, entry.payload.imm);
      Addr vaddr = entry.operands.vj + immVal;
      ExcpInfo excp = checkMemHasExcp(entry.payload.mask, vaddr, mkNoExcp);

      if (excp.valid) begin
        memExecEntry <= entry;
        memVaddr <= vaddr;
        memPaddr <= 0;
        memNeedTlb <= False;
        memExcpInfo <= excp;
        memState <= MemExcpWait;
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
    end
  endaction
endfunction

function Action doReportMemExcpBody(
    Reg#(MemExecState) memState,
    Reg#(MemIssueEntry) memExecEntry,
    Reg#(ExcpInfo) memExcpInfo,
    ROB rob,
    MemRS memRS
);
  action
    let entry = memExecEntry;
    if (rob.tokenAlive(entry.payload.token)) begin
      rob.updateExcp(entry.payload.token, memExcpInfo);
      rob.updateMem(entry.payload.token, RobCompleted);
      memRS.remove(entry.payload.token);
    end
    memState <= MemIdle;
  endaction
endfunction

endpackage
