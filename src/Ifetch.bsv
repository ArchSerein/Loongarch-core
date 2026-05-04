package Ifetch;

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
import Fifo::*;
import Ehr::*;
import Btb::*;
import Bht::*;
import ICache::*;
import Tlb::*;
import Mmu::*;
import CoreTypes::*;
import CoreFunc::*;
`ifdef CONFIG_TRACE_PERFORMANCE
import Perf::*;
`endif
`include "CsrAddr.bsv"

// IF1 Stage: Instruction Fetch Stage 1
// Handles PC generation, branch prediction, and initiates ICache and TLB requests.
function Action doIF1Body(
    Addr pc, 
    Data crmd, 
    Data asid, 
    Data dmw0, 
    Data dmw1, 
    MmuTranslateType transType,
    Btb#(6) btb,
    Bht#(8) bht,
    ICache iCache,
    Fifo#(2, F1toF2) f1f2Fifo,
    Reg#(Addr) pcReg
);
    action
    // Branch Prediction Integration
    // Predict branch target using BTB and branch direction using BHT
    Addr btbPc = btb.predPc(pc);
    Bool bhtPred = bht.predict(pc);
    Addr predPc = bhtPred ? btbPc : pc + 4;

    // Send requests to IF2 stage and initiate ICache probe
    f1f2Fifo.enq(F1toF2{
      pc: pc,
      predPc: predPc,
      crmd: crmd,
      asid: asid,
      dmw0: dmw0,
      dmw1: dmw1,
      transType: transType,
      probeRes: iCache.probe(pc)
    });
    // Update PC to the predicted PC
    pcReg <= predPc;
    endaction
endfunction

// IF2 Stage: Instruction Fetch Stage 2
// Handles memory translation, ICache response, and exception detection.
function Action doIF2Body(
    TlbLookupResult tlbRes,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    ICache iCache,
    Reg#(F1toF2) if2PendingReq,
    Reg#(Addr) if2MissPaddr,
    Reg#(Bool) if2WaitRefill
);
    action
    let req = f1f2Fifo.first();
    ICacheProbeResp probeRes = req.probeRes;
    
    // Address translation result
    MmuResult fTrans = MmuResult{
      pa: req.pc,
      mat: getFetchMatType(req.crmd),
      fromDmw: False,
      fromTlb: False,
      excValid: False,
      ecode: 0,
      esubcode: 0,
      badv: req.pc
    };

    // Perform TLB translation if required
    if (req.transType == Translate) begin
      fTrans = mmuTranslate(req.pc, MmuFetch, req.crmd, req.asid, req.dmw0, req.dmw1, tlbRes);
    end else if (req.transType == None) begin
      fTrans.excValid = True;
      fTrans.ecode = `ECODE_ADE;
      fTrans.esubcode = `ESUBCODE_ADEF;
    end

    // Exception handling: PC alignment or TLB miss/invalid
    if (req.pc[1:0] != 2'b00) begin
      f2dFifo.enq(F2D{
        pc: req.pc,
        predPc: req.predPc,
        inst: 0,
        instPaddr: 0,
        excp: mkExcp(`ECODE_ADE, `ESUBCODE_ADEF, req.pc)
      });
      f1f2Fifo.deq();
    end else if (fTrans.excValid) begin
      f2dFifo.enq(F2D{
        pc: req.pc,
        predPc: req.predPc,
        inst: 0,
        instPaddr: 0,
        excp: mkExcp(fTrans.ecode, fTrans.esubcode, fTrans.badv)
      });
      f1f2Fifo.deq();
    end else begin
      // Cache tag matching and hit detection
      Bool fetchUseCache = matUseCache(req.transType, fTrans.mat, req.crmd, MmuFetch);
      ICacheTag paTag = getITag(fTrans.pa);
      Bool hit = False;
      ICacheWayIdx hitWay = 0;
      Instruction hitInst = 0;

      for (Integer w = 0; w < valueOf(ICacheWays); w = w + 1) begin
        if (probeRes[w].valid && probeRes[w].tag == paTag) begin
          hit = True;
          hitWay = fromInteger(w);
          hitInst = probeRes[w].inst;
        end
      end

      if (fetchUseCache && hit) begin
        // ICache hit, proceed to Decode stage
        iCache.commitHit(req.pc, hitWay);
        f2dFifo.enq(F2D{
          pc: req.pc,
          predPc: req.predPc,
          inst: hitInst,
          instPaddr: fTrans.pa,
          excp: mkNoExcp
        });
        f1f2Fifo.deq();
      end else begin
        // ICache miss, initiate cache refill
`ifdef CONFIG_TRACE_PERFORMANCE
        perf_icache_miss();
`endif
        iCache.refillReq(fTrans.pa, fetchUseCache);
        if2PendingReq <= req;
        if2MissPaddr <= fTrans.pa;
        if2WaitRefill <= True;
      end
    end
    endaction
endfunction

endpackage
