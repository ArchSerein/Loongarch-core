package CoreMemory;

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
import Scoreboard::*;
import CsrFile::*;
import DCache::*;
import ICache::*;
import Tlb::*;
import Mmu::*;
import CoreFunc::*;
import CoreTypes::*;
`include "CsrAddr.bsv"
`ifdef CONFIG_DIFFTEST
import DiffTypes::*;
import Difftest::*;
`endif

function Action doMemoryStage1Body(
    TlbLookupResult tlbRes,
    Fifo#(2, E2M) e2mFifo,
    Fifo#(2, M1toM2) m1m2Fifo,
    CsrFile csrf,
    Scoreboard#(8) regSb,
    DCache dCache,
    ICache iCache,
    TlbArray tlb,
    Reg#(Bool) memRedirectPending
);
    action
    let execPkt = e2mFifo.first();
    Mem2Op nextOp = M2OpNone;
    Addr memPaddr = 0;
    ExcpInfo memExcp = execPkt.excp;
    Maybe#(ExecInst) nextInst = execPkt.eInst;

    if (execPkt.eInst matches tagged Valid .eInst) begin
      ExecInst memInst = eInst;
      Bool isLoad = (eInst.iType == Ld || eInst.iType == Ll);
      Bool isStore = (eInst.iType == St);
      Bool isSc = (eInst.iType == Sc);
      Bool isBarrier = coreIsBarrier(eInst.iType);
      Bool isCacop = (eInst.iType == Cacop);
      Bit#(5) cacheOp = fromMaybe(0, eInst.cacheOp);
      Bool cacopNeedsICache = isCacop && cacheOp[2:0] == 3'b000;
      Bool cacopNeedsDCache = isCacop && cacheOp[2:0] != 3'b000;
      Bool isTlbOp = (eInst.iType == Tlbsrch || eInst.iType == Tlbrd ||
        eInst.iType == Tlbwr || eInst.iType == Tlbfill || eInst.iType == Invtlb);
      Bool memDCacheSideEffect = isStore || isSc || isBarrier ||
        cacopNeedsDCache || cacopNeedsICache || isTlbOp;
      Bool memIsCsrWrite = (eInst.iType == Csrw || eInst.iType == Csrxchg);
      Bool has_int = csrf.hasInterrupt(memIsCsrWrite ? eInst.csr : tagged Invalid,
        eInst.addr, memDCacheSideEffect);
      memExcp = has_int ? mkExcp(`ECODE_INT, 0, 0) : execPkt.excp;
      Bool canIssueMem = !memExcp.valid && !memRedirectPending;
      ByteMask m = fromMaybe(5'b00000, execPkt.mask);
      let storePkt = selectStoreData(eInst.data, eInst.addr[1:0], m[3:0]);
      Bit#(WordSz) storeByteEn = tpl_1(storePkt);
      Data storeWData = tpl_2(storePkt);
      Bool memUseCache = True;
      Bool setRedirectPending = memExcp.valid || execPkt.isNeedFlush ||
        eInst.iType == Ertn;

      memPaddr = eInst.addr;
      if (canIssueMem) begin
        Bool dCacheCacop = isCacop && cacopNeedsDCache;
        if (isLoad || isStore || isSc || dCacheCacop || cacopNeedsICache) begin
          MmuAccessType accessType = (isStore || isSc) ? MmuStore : MmuLoad;
          Data crmd = csrf.crmd;
          MmuTranslateType transType = getMmuTranslateType(crmd);
          MmuResult dTrans = MmuResult{
            pa: eInst.addr, mat: getDataMatType(crmd), fromDmw: False,
            fromTlb: False, excValid: False, ecode: 0, esubcode: 0,
            badv: eInst.addr
          };
          if (transType == Translate) begin
            dTrans = mmuTranslate(eInst.addr, accessType, crmd, csrf.asid,
              csrf.dmw0, csrf.dmw1, tlbRes);
          end else if (transType == None) begin
            dTrans.excValid = True;
            dTrans.ecode = `ECODE_ADE;
            dTrans.esubcode = `ESUBCODE_ADEM;
          end
          memPaddr = dTrans.pa;
          memUseCache = matUseCache(transType, dTrans.mat, crmd, accessType);
          if (dTrans.excValid) begin
            memExcp = mkExcp(dTrans.ecode, dTrans.esubcode, dTrans.badv);
            setRedirectPending = True;
            canIssueMem = False;
          end
        end
      end

      if (setRedirectPending) begin
        memRedirectPending <= True;
      end

      Bool needsDCache = canIssueMem &&
        (isLoad || isStore || isSc || isBarrier || cacopNeedsDCache);

      if (needsDCache) begin
        // Cache Interaction: Issue request to L1 Data Cache for loads, stores,
        // atomics (Sc), memory barriers, or data cache operations.
        Bit#(WordSz) byteEn = 4'b0000;
        Data wData = 0;
        MemOp memOp = Ld;
        if (isLoad) begin
          memOp = (eInst.iType == Ll) ? Ll : Ld;
        end else if (isStore || isSc) begin
          byteEn = storeByteEn;
          wData = storeWData;
          memOp = isSc ? Sc : St;
        end else if (isBarrier) begin
          memOp = Barrier;
        end else if (cacopNeedsDCache) begin
          memOp = Cacop;
        end

        let cacheReq = MemReq {
          op: memOp,
          addr: memInst.addr,
          paddr: memPaddr,
          useCache: (memOp == Cacop || memOp == Barrier) ? True : memUseCache,
          data: wData,
          byteEn: byteEn,
          cacheOp: isCacop ? cacheOp : 5'b0
        };
        if (memOp == Cacop) begin
          dCache.cacop(cacheReq);
        end else begin
          dCache.req(cacheReq);
        end
        nextOp = M2OpDCache;
      end else if (canIssueMem && cacopNeedsICache) begin
        iCache.cacop(cacheOp, eInst.addr, memPaddr);
        nextOp = M2OpICache;
      end else if (canIssueMem && isTlbOp) begin
        TlbOp op = TlbOpSearch;
        Data tlbReqAsid = (eInst.iType == Invtlb) ? eInst.data : csrf.tlbWriteAsid;
        if (eInst.iType == Tlbrd) op = TlbOpRead;
        else if (eInst.iType == Tlbwr) op = TlbOpWrite;
        else if (eInst.iType == Tlbfill) op = TlbOpFill;
        else if (eInst.iType == Invtlb) op = TlbOpInv;
        tlb.req(TlbReq{
          op: op,
          tlbidx: (eInst.iType == Tlbrd) ? zeroExtend(csrf.tlbReadIndex) : csrf.tlbWriteIdx,
          invOp: truncate(fromMaybe(0, eInst.imm)),
          ehi: csrf.tlbWriteEhi,
          elo0: csrf.tlbWriteElo0,
          elo1: csrf.tlbWriteElo1,
          asid: tlbReqAsid,
          va: eInst.addr
        });
        nextOp = M2OpTlb;
      end

    end

    Maybe#(Data) mem1Result = tagged Invalid;
    if (nextInst matches tagged Valid .mem1Inst) begin
      Bool isLoadOp = (mem1Inst.iType == Ld || mem1Inst.iType == Ll || mem1Inst.iType == Sc);
      Bool isTlbOp  = (mem1Inst.iType == Tlbsrch || mem1Inst.iType == Tlbrd || 
                       mem1Inst.iType == Tlbwr   || mem1Inst.iType == Tlbfill || mem1Inst.iType == Invtlb);
      Bool isCacop  = (mem1Inst.iType == Cacop);
      
      Bool mem1ResultReady = !(isLoadOp || isTlbOp || isCacop); 
      
      if (mem1ResultReady && isValid(mem1Inst.dst)) begin
        mem1Result = tagged Valid mem1Inst.data;
      end
    end
    regSb.updateMem1(execPkt.sbTag, mem1Result);

    e2mFifo.deq();
    m1m2Fifo.enq(M1toM2{
      pc: execPkt.pc,
`ifdef CONFIG_DIFFTEST
      inst: execPkt.inst,
      csrSnapshot: csrf.diffSnapshot,
`else
`ifdef CONFIG_WB_DEBUG_INST
      inst: execPkt.inst,
`endif
`endif
      excp: memExcp,
      mask: execPkt.mask,
      isNeedFlush: execPkt.isNeedFlush,
      sbTag: execPkt.sbTag,
      eInst: nextInst,
      m2Op: nextOp,
      memPaddr: memPaddr
    });
    endaction
endfunction

function Action doMemoryStage2Body(
    Maybe#(DCacheResp) dCacheResp,
    Maybe#(Bool) iCacheResp,
    Maybe#(TlbReadResult) tlbResp,
    Fifo#(2, M1toM2) m1m2Fifo,
    Fifo#(2, M2W) m2wFifo,
    Scoreboard#(8) regSb,
    CsrFile csrf
);
    action
    let memPkt = m1m2Fifo.first();
    Maybe#(ExecInst) nextInst = memPkt.eInst;
    Maybe#(TlbReadResult) tlbResult = tagged Invalid;
    ExcpInfo memExcp = memPkt.excp;

    if (memPkt.m2Op == M2OpDCache &&&
        memPkt.eInst matches tagged Valid .mInst &&&
        dCacheResp matches tagged Valid .d) begin
      ExecInst doneInst = mInst;
      Bool isLoad = (doneInst.iType == Ld || doneInst.iType == Ll);
      Bool isStore = (doneInst.iType == St);
      Bool isSc = (doneInst.iType == Sc);
      ByteMask m = fromMaybe(5'b00000, memPkt.mask);
      if (isLoad) begin
        if (doneInst.iType == Ld) begin
          doneInst.data = selectLoadData(d.data, doneInst.addr[1:0],
            m[3:0], m[4] == 1'b1);
        end else begin
          doneInst.data = d.data;
        end
      end
      if (isSc) begin
        doneInst.data = d.data;
      end
      nextInst = tagged Valid doneInst;
    end else if (memPkt.m2Op == M2OpTlb &&&
        memPkt.eInst matches tagged Valid .mInst &&&
        tlbResp matches tagged Valid .res) begin
      tlbResult = tagged Valid res;
      if (!memExcp.valid) begin
        if (mInst.iType == Tlbsrch) begin
          Data srchResult = 0;
          if (res.ne) srchResult[`CSR_TLBIDX_NE] = 1'b1;
          else srchResult[`CSR_TLBIDX_INDEX] = res.ehi[`CSR_TLBIDX_INDEX];
          csrf.applyTlbsrchResult(srchResult);
        end else if (mInst.iType == Tlbrd) begin
          csrf.applyTlbrdResult(res.ne, res.ps, res.ehi, res.elo0,
            res.elo1, res.asid);
        end else if (mInst.iType == Tlbwr || mInst.iType == Tlbfill) begin
          csrf.commitTlbOp;
        end
      end
    end else if (memPkt.m2Op == M2OpICache &&&
        iCacheResp matches tagged Valid .done) begin
      noAction;
    end

`ifdef CONFIG_DIFFTEST
    Maybe#(DiffMemOp) diffMemInfo = tagged Invalid;
    if (memPkt.m2Op == M2OpDCache &&&
        memPkt.eInst matches tagged Valid .origInst &&&
        nextInst matches tagged Valid .dInst) begin
      Bool isLoad = (dInst.iType == Ld || dInst.iType == Ll);
      Bool isStore = (dInst.iType == St);
      Bool isSc = (dInst.iType == Sc);
      ByteMask m = fromMaybe(5'b00000, memPkt.mask);
      let storePkt = selectStoreData(origInst.data, origInst.addr[1:0], m[3:0]);
      if (!memExcp.valid && (isLoad || isStore || isSc)) begin
        diffMemInfo = tagged Valid DiffMemOp{
          isLoad: isLoad,
          isStore: isStore || isSc,
          isSc: isSc,
          paddr: memPkt.memPaddr,
          vaddr: dInst.addr,
          storeData: tpl_2(storePkt)
        };
      end
    end
`endif

    Maybe#(Data) mem2Result = tagged Invalid;
    if (nextInst matches tagged Valid .mem2Inst &&& isValid(mem2Inst.dst)) begin
      mem2Result = tagged Valid mem2Inst.data;
    end
    regSb.updateMem2(memPkt.sbTag, mem2Result);

    m1m2Fifo.deq();
    m2wFifo.enq(M2W{
      pc: memPkt.pc,
`ifdef CONFIG_DIFFTEST
      inst: memPkt.inst,
      csrSnapshot: memPkt.csrSnapshot,
`else
`ifdef CONFIG_WB_DEBUG_INST
      inst: memPkt.inst,
`endif
`endif
      excp: memExcp,
      memPaddr: memPkt.memPaddr,
      isNeedFlush: memPkt.isNeedFlush,
      sbTag: memPkt.sbTag,
      mInst: nextInst,
      tlbResult: tlbResult
`ifdef CONFIG_DIFFTEST
      , diffMem: diffMemInfo
`endif
    });
    endaction
endfunction

endpackage
