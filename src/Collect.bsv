package Collect;

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
import CsrFile::*;
import Mmu::*;
import Tlb::*;
import ICache::*;
import DCache::*;
import Mul::*;
import Div::*;
import CoreTypes::*;
import CoreFunc::*;
import OoOTypes::*;
import ROB::*;
import ResStation::*;
import StoreBuf::*;
import CDB::*;

`include "CsrAddr.bsv"

function StoreForwardResult mergeForward(StoreForwardResult older, StoreForwardResult newer);
  return StoreForwardResult{
    data: coreApplyByteMask(older.data, newer.data, truncate(newer.byteEn)),
    byteEn: older.byteEn | newer.byteEn
  };
endfunction

function Action doCollectMulBody(
    Reg#(Bool) mulInFlight,
    Reg#(MulDivIssueEntry) mulExecEntry,
    Mul_ifc mulUnit,
    CDB cdb,
    ROB rob
);
  action
    let entry = mulExecEntry;
    mulInFlight <= False;
    if (rob.tokenAlive(entry.payload.token)) begin
      let mdFunc = fromMaybe(?, entry.payload.muldivFunc);
      Data result = ?;
      case (mdFunc)
        MulW:    result = truncate(mulUnit.result);
        MulhW:   result = truncateLSB(mulUnit.result);
        MulhWu:  result = truncateLSB(mulUnit.result);
      endcase
      if (entry.payload.pDst matches tagged Valid .pd) begin
        cdb.sendMul(pd, result);
      end
      rob.updateMul(entry.payload.token, RobCompleted);
    end
  endaction
endfunction

function Action doCollectDivBody(
    Reg#(Bool) divInFlight,
    Reg#(MulDivIssueEntry) divExecEntry,
    Div_ifc divUnit,
    CDB cdb,
    ROB rob
);
  action
    let entry = divExecEntry;
    divInFlight <= False;
    if (rob.tokenAlive(entry.payload.token)) begin
      let mdFunc = fromMaybe(?, entry.payload.muldivFunc);
      Data result = ?;
      case (mdFunc)
        DivW:    result = truncate(divUnit.result);
        DivWu:   result = truncate(divUnit.result);
        ModW:    result = truncateLSB(divUnit.result);
        ModWu:   result = truncateLSB(divUnit.result);
      endcase
      if (entry.payload.pDst matches tagged Valid .pd) begin
        cdb.sendDiv(pd, result);
      end
      rob.updateDiv(entry.payload.token, RobCompleted);
    end
  endaction
endfunction

function StoreBufEntry makeStoreEntry(MemIssueEntry entry, Addr vaddr, Addr paddr, Bool useCache, Data data, Bit#(WordSz) byteEn);
  return StoreBufEntry{
    owner: entry.payload.token,
    state: StoreSpeculative,
    vaddr: vaddr,
    paddr: paddr,
    useCache: useCache,
    data: data,
    byteEn: extend(byteEn)
  };
endfunction

function MemReq makeMemReq(MemIssueEntry entry, Addr vaddr, Addr paddr, Bool useCache, MemOp memOp, Data wData, Bit#(WordSz) byteEn, MemReqGen gen, Bool squashable);
  Bool isCacop = (entry.payload.iType == Cacop);
  return MemReq{
    op: memOp, addr: vaddr, paddr: paddr,
    useCache: (memOp == Cacop || memOp == Barrier) ? True : useCache,
    gen: gen, squashable: squashable,
    data: wData, byteEn: byteEn,
    size: memByteEnToAxiSize(truncate(fromMaybe(5'b0, entry.payload.mask))),
    cacheOp: isCacop ? fromMaybe(0, entry.payload.cacheOp) : 5'b0
  };
endfunction

function MemOp expectedDCacheRespOp(MemIssueEntry entry);
  MemOp ret = Ld;
  if (entry.payload.isLoad) begin
    ret = (entry.payload.iType == Ll) ? Ll : Ld;
  end else if (entry.payload.iType == Sc) begin
    ret = Sc;
  end else if (entry.payload.iType == Dbar) begin
    ret = Barrier;
  end else if (entry.payload.iType == Cacop) begin
    ret = Cacop;
  end
  return ret;
endfunction

function Action doCollectMemTLBBody(
    Reg#(MemExecState) memState,
    Reg#(MemIssueEntry) memExecEntry,
    Reg#(Addr) memVaddr,
    Reg#(Addr) memPaddr,
    Reg#(StoreForwardResult) memForward,
    Reg#(MemReqGen) memReqGen,
    CsrFile csrf,
    TlbArray tlb,
    ICache iCache,
    DCache dCache,
    ROB rob,
    MemRS memRS,
    StoreBuf#(16) storeBuf
);
  action
    let tlbRes <- tlb.dataLookupResp;
    let entry = memExecEntry;
    if (!rob.tokenAlive(entry.payload.token)) begin
      memState <= MemIdle;
    end else begin
      Addr vaddr = memVaddr;
      MmuAccessType accessType = entry.payload.isStore ? MmuStore : MmuLoad;
      MmuResult dTrans = mmuTranslate(vaddr, accessType, csrf.crmd, csrf.asid,
        csrf.dmw0, csrf.dmw1, tlbRes);
      if (dTrans.excValid) begin
        ExcpInfo memExcp = mkExcp(dTrans.ecode, dTrans.esubcode, dTrans.badv);
        rob.updateExcp(entry.payload.token, memExcp);
        rob.updateMem(entry.payload.token, RobCompleted);
        memRS.remove(entry.payload.token);
        memState <= MemIdle;
      end else begin
        memPaddr <= dTrans.pa;
        Bit#(5) cacheOp = fromMaybe(0, entry.payload.cacheOp);
        Bool isCacop = (entry.payload.iType == Cacop);
        if (isCacop && cacheOp[2:0] == 3'b000) begin
          iCache.cacop(cacheOp, vaddr, dTrans.pa);
          memState <= MemCacopIWait;
        end else begin
          Bool memUseCache = matUseCache(Translate, dTrans.mat, csrf.crmd, accessType);
          if (entry.payload.iType == St) begin
            ByteMask m = fromMaybe(5'b00000, entry.payload.mask);
            let storePkt = selectStoreData(entry.operands.vk, vaddr[1:0], m[3:0]);
            storeBuf.enqSpeculative(makeStoreEntry(entry, vaddr, dTrans.pa, memUseCache,
              tpl_2(storePkt), tpl_1(storePkt)));
            rob.updateMemInfo(entry.payload.token, vaddr, dTrans.pa, memUseCache, entry.payload.mask);
            rob.updateMem(entry.payload.token, RobCompleted);
            memRS.remove(entry.payload.token);
            memState <= MemIdle;
          end else begin
            Bit#(WordSz) byteEn = 4'b0000;
            Data wData = 0;
            MemOp memOp = Ld;
            if (entry.payload.isLoad) begin
              memOp = (entry.payload.iType == Ll) ? Ll : Ld;
            end else if (entry.payload.iType == Sc) begin
              ByteMask m = fromMaybe(5'b00000, entry.payload.mask);
              let storePkt = selectStoreData(entry.operands.vk, vaddr[1:0], m[3:0]);
              byteEn = tpl_1(storePkt); wData = tpl_2(storePkt); memOp = Sc;
            end else if (entry.payload.iType == Dbar) begin
              memOp = Barrier;
            end else if (isCacop) begin
              memOp = Cacop;
            end
            MemReqGen reqGen = dCache.generation;
            let cacheReq = makeMemReq(entry, vaddr, dTrans.pa, memUseCache, memOp, wData, byteEn, reqGen, True);
            memForward <= entry.payload.isLoad ?
              storeBuf.forwardForLoad(entry.payload.token, rob.headTag, dTrans.pa) :
              StoreForwardResult{data: 0, byteEn: 0};
            if (memOp != Barrier) begin
              rob.updateMemInfo(entry.payload.token, vaddr, dTrans.pa, memUseCache, entry.payload.mask);
            end
            if (entry.payload.iType == Ld && !memUseCache && entry.payload.robTag != rob.headTag) begin
              memState <= MemUncacheWait;
            end else begin
              if (memOp == Cacop) dCache.cacop(cacheReq);
              else dCache.req(cacheReq);
              memReqGen <= reqGen;
              memState <= MemCacheWait;
            end
          end
        end
      end
    end
  endaction
endfunction

function Action doCollectMemDirectBody(
    Reg#(MemExecState) memState,
    Reg#(MemIssueEntry) memExecEntry,
    Reg#(Addr) memVaddr,
    Reg#(Addr) memPaddr,
    Reg#(StoreForwardResult) memForward,
    Reg#(MemReqGen) memReqGen,
    CsrFile csrf,
    ICache iCache,
    DCache dCache,
    ROB rob,
    MemRS memRS,
    StoreBuf#(16) storeBuf
);
  action
    let entry = memExecEntry;
    if (!rob.tokenAlive(entry.payload.token)) begin
      memState <= MemIdle;
    end else begin
      Addr vaddr = memVaddr;
      Addr paddr = memPaddr;
      Bit#(5) cacheOp = fromMaybe(0, entry.payload.cacheOp);
      Bool isCacop = (entry.payload.iType == Cacop);
      if (isCacop && cacheOp[2:0] == 3'b000) begin
        iCache.cacop(cacheOp, vaddr, paddr);
        memState <= MemCacopIWait;
      end else begin
        MmuAccessType accessType = entry.payload.isStore ? MmuStore : MmuLoad;
        Bool memUseCache = matUseCache(Direct, Cc, csrf.crmd, accessType);
        if (entry.payload.iType == St) begin
          ByteMask m = fromMaybe(5'b00000, entry.payload.mask);
          let storePkt = selectStoreData(entry.operands.vk, vaddr[1:0], m[3:0]);
          storeBuf.enqSpeculative(makeStoreEntry(entry, vaddr, paddr, memUseCache,
            tpl_2(storePkt), tpl_1(storePkt)));
          rob.updateMemInfo(entry.payload.token, vaddr, paddr, memUseCache, entry.payload.mask);
          rob.updateMem(entry.payload.token, RobCompleted);
          memRS.remove(entry.payload.token);
          memState <= MemIdle;
        end else begin
          Bit#(WordSz) byteEn = 4'b0000;
          Data wData = 0;
          MemOp memOp = Ld;
          if (entry.payload.isLoad) begin
            memOp = (entry.payload.iType == Ll) ? Ll : Ld;
          end else if (entry.payload.iType == Sc) begin
            ByteMask m = fromMaybe(5'b00000, entry.payload.mask);
            let storePkt = selectStoreData(entry.operands.vk, vaddr[1:0], m[3:0]);
            byteEn = tpl_1(storePkt); wData = tpl_2(storePkt); memOp = Sc;
          end else if (entry.payload.iType == Dbar) begin
            memOp = Barrier;
          end else if (isCacop) begin
            memOp = Cacop;
          end
          MemReqGen reqGen = dCache.generation;
          let cacheReq = makeMemReq(entry, vaddr, paddr, memUseCache, memOp, wData, byteEn, reqGen, True);
          memForward <= entry.payload.isLoad ?
            storeBuf.forwardForLoad(entry.payload.token, rob.headTag, paddr) :
            StoreForwardResult{data: 0, byteEn: 0};
          if (memOp != Barrier) begin
            rob.updateMemInfo(entry.payload.token, vaddr, paddr, memUseCache, entry.payload.mask);
          end
          if (entry.payload.iType == Ld && !memUseCache && entry.payload.robTag != rob.headTag) begin
            memState <= MemUncacheWait;
          end else begin
            if (memOp == Cacop) dCache.cacop(cacheReq);
            else dCache.req(cacheReq);
            memReqGen <= reqGen;
            memState <= MemCacheWait;
          end
        end
      end
    end
  endaction
endfunction

function Action doIssueMemUncacheBody(
    Reg#(MemExecState) memState,
    Reg#(MemIssueEntry) memExecEntry,
    Reg#(Addr) memVaddr,
    Reg#(Addr) memPaddr,
    Reg#(StoreForwardResult) memForward,
    Reg#(MemReqGen) memReqGen,
    DCache dCache,
    StoreBuf#(16) storeBuf,
    RobTag headTag
);
  action
    let entry = memExecEntry;
    Addr vaddr = memVaddr;
    Addr paddr = memPaddr;
    ByteMask mask = fromMaybe(5'b0, entry.payload.mask);
    MemReqGen reqGen = dCache.generation;
    memForward <= storeBuf.forwardForLoad(entry.payload.token, headTag, paddr);
    memReqGen <= reqGen;
    dCache.req(MemReq{
      op: Ld, addr: vaddr, paddr: paddr, useCache: False,
      gen: reqGen, squashable: True,
      data: 0, byteEn: 0,
      size: memByteEnToAxiSize(truncate(mask)), cacheOp: 0
    });
    memState <= MemCacheWait;
  endaction
endfunction

function Action doCollectMemCacheBody(
    Reg#(MemExecState) memState,
    Reg#(MemIssueEntry) memExecEntry,
    Reg#(Addr) memVaddr,
    Reg#(Addr) memPaddr,
    Reg#(StoreForwardResult) memForward,
    Reg#(MemReqGen) memReqGen,
    DCache dCache,
    CDB cdb,
    ROB rob,
    MemRS memRS
);
  action
    let d <- dCache.resp;
    let entry = memExecEntry;
    Bool live = rob.tokenAlive(entry.payload.token);
    Bool respMatches = d.gen == memReqGen && d.op == expectedDCacheRespOp(entry);

    if (!live) begin
      memState <= MemIdle;
    end else if (!respMatches) begin
      memState <= MemCacheWait;
    end else begin
      memState <= MemIdle;
      if (entry.payload.isLoad) begin
        ByteMask m = fromMaybe(5'b00000, entry.payload.mask);
        StoreForwardResult fwd = memForward;
        Data rawData = coreApplyByteMask(d.data, fwd.data, truncate(fwd.byteEn));
        Data loadData = ?;
        if (entry.payload.iType == Ll)
          loadData = rawData;
        else
          loadData = selectLoadData(rawData, memVaddr[1:0], m[3:0], m[4] == 1'b1);
        if (entry.payload.pDst matches tagged Valid .pd) begin
          cdb.sendLoad(pd, loadData);
        end
        rob.updateMem(entry.payload.token, RobCompleted);
      end else if (entry.payload.iType == Sc) begin
        if (entry.payload.pDst matches tagged Valid .pd) begin
          cdb.sendLoad(pd, d.data);
        end
        rob.updateMem(entry.payload.token, RobCompleted);
      end else begin
        rob.updateMem(entry.payload.token, RobCompleted);
      end
      memRS.remove(entry.payload.token);
    end
  endaction
endfunction

function Action doCollectMemCacopIBody(
    Reg#(MemExecState) memState,
    Reg#(MemIssueEntry) memExecEntry,
    ICache iCache,
    ROB rob,
    MemRS memRS
);
  action
    let done <- iCache.cacopResp;
    let entry = memExecEntry;
    memState <= MemIdle;
    if (rob.tokenAlive(entry.payload.token)) begin
      rob.updateMem(entry.payload.token, RobCompleted);
      memRS.remove(entry.payload.token);
    end
  endaction
endfunction

function Action doCollectMemIbarBody(
    Reg#(MemExecState) memState,
    Reg#(MemIssueEntry) memExecEntry,
    ICache iCache,
    ROB rob,
    MemRS memRS
);
  action
    let done <- iCache.invalidateResp;
    let entry = memExecEntry;
    memState <= MemIdle;
    if (rob.tokenAlive(entry.payload.token)) begin
      rob.updateMem(entry.payload.token, RobCompleted);
      memRS.remove(entry.payload.token);
    end
  endaction
endfunction

endpackage
