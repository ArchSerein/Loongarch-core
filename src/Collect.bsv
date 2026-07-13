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
    Reg#(RSEntry) mulExecEntry,
    Mul_ifc mulUnit,
    CDB cdb,
    ROB rob
);
  action
    let entry = mulExecEntry;
    mulInFlight <= False;
    let mdFunc = fromMaybe(?, entry.muldivFunc);
    Data result = ?;
    case (mdFunc)
      MulW:    result = truncate(mulUnit.result);
      MulhW:   result = truncateLSB(mulUnit.result);
      MulhWu:  result = truncateLSB(mulUnit.result);
    endcase
    if (entry.pDst matches tagged Valid .pd) begin
      cdb.sendMul(pd, result);
    end
    rob.updateMul(entry.robTag, RobCompleted);
  endaction
endfunction

function Action doCollectDivBody(
    Reg#(Bool) divInFlight,
    Reg#(RSEntry) divExecEntry,
    Div_ifc divUnit,
    CDB cdb,
    ROB rob
);
  action
    let entry = divExecEntry;
    divInFlight <= False;
    let mdFunc = fromMaybe(?, entry.muldivFunc);
    Data result = ?;
    case (mdFunc)
      DivW:    result = truncate(divUnit.result);
      DivWu:   result = truncate(divUnit.result);
      ModW:    result = truncateLSB(divUnit.result);
      ModWu:   result = truncateLSB(divUnit.result);
    endcase
    if (entry.pDst matches tagged Valid .pd) begin
      cdb.sendDiv(pd, result);
    end
    rob.updateDiv(entry.robTag, RobCompleted);
  endaction
endfunction

function Action doCollectMemTLBBody(
    Reg#(MemExecState) memState,
    Reg#(RSEntry) memExecEntry,
    Reg#(Addr) memVaddr,
    Reg#(Addr) memPaddr,
    Reg#(StoreForwardResult) memForward,
    CsrFile csrf,
    TlbArray tlb,
    ICache iCache,
    DCache dCache,
    ROB rob,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    StoreForwardBuf#(16) committedStoreBuf
);
  action
    let tlbRes <- tlb.dataLookupResp;
    let entry = memExecEntry;
    Addr vaddr = memVaddr;
    MmuAccessType accessType = entry.isStore ? MmuStore : MmuLoad;
    MmuResult dTrans = mmuTranslate(vaddr, accessType, csrf.crmd, csrf.asid,
      csrf.dmw0, csrf.dmw1, tlbRes);
    if (dTrans.excValid) begin
      ExcpInfo memExcp = mkExcp(dTrans.ecode, dTrans.esubcode, dTrans.badv);
      rob.updateExcp(entry.robTag, memExcp);
      rob.updateMem(entry.robTag, RobCompleted);
      memRS.remove(entry.robTag);
      memState <= MemIdle;
    end else begin
      memPaddr <= dTrans.pa;
      Bit#(5) cacheOp = fromMaybe(0, entry.cacheOp);
      Bool isCacop = (entry.iType == Cacop);
      if (isCacop && cacheOp[2:0] == 3'b000) begin
        iCache.cacop(cacheOp, vaddr, dTrans.pa);
        memState <= MemCacopIWait;
      end else begin
        Bool memUseCache = matUseCache(Translate, dTrans.mat, csrf.crmd, accessType);
        if (entry.iType == St) begin
          ByteMask m = fromMaybe(5'b00000, entry.mask);
          let storePkt = selectStoreData(entry.vk, vaddr[1:0], m[3:0]);
          storeBuf.enq(StoreBufEntry{
            addr: vaddr, data: tpl_2(storePkt),
            byteEn: extend(tpl_1(storePkt))
          });
          rob.updateMemInfo(entry.robTag, vaddr, dTrans.pa, memUseCache, entry.mask);
          rob.updateMem(entry.robTag, RobCompleted);
          memRS.remove(entry.robTag);
          memState <= MemIdle;
        end else begin
          Bit#(WordSz) byteEn = 4'b0000;
          Data wData = 0;
          MemOp memOp = Ld;
          if (entry.isLoad) begin
            memOp = (entry.iType == Ll) ? Ll : Ld;
          end else if (entry.iType == Sc) begin
            ByteMask m = fromMaybe(5'b00000, entry.mask);
            let storePkt = selectStoreData(entry.vk, vaddr[1:0], m[3:0]);
            byteEn = tpl_1(storePkt); wData = tpl_2(storePkt); memOp = Sc;
          end else if (coreIsBarrier(entry.iType)) begin
            memOp = Barrier;
          end else if (isCacop) begin
            memOp = Cacop;
          end
          let cacheReq = MemReq{
            op: memOp, addr: vaddr, paddr: dTrans.pa,
            useCache: (memOp == Cacop || memOp == Barrier) ? True : memUseCache,
            data: wData, byteEn: byteEn,
            size: memByteEnToAxiSize(truncate(fromMaybe(5'b0, entry.mask))),
            cacheOp: isCacop ? cacheOp : 5'b0
          };
          memForward <= entry.isLoad ?
            mergeForward(committedStoreBuf.forward(vaddr), storeBuf.forward(vaddr)) :
            StoreForwardResult{data: 0, byteEn: 0};
          rob.updateMemInfo(entry.robTag, vaddr, dTrans.pa, memUseCache, entry.mask);
          if (entry.iType == Ld && !memUseCache && entry.robTag != rob.headTag) begin
            memState <= MemUncacheWait;
          end else begin
            if (memOp == Cacop) dCache.cacop(cacheReq);
            else dCache.req(cacheReq);
            memState <= MemCacheWait;
          end
        end
      end
    end
  endaction
endfunction

function Action doCollectMemDirectBody(
    Reg#(MemExecState) memState,
    Reg#(RSEntry) memExecEntry,
    Reg#(Addr) memVaddr,
    Reg#(Addr) memPaddr,
    Reg#(StoreForwardResult) memForward,
    CsrFile csrf,
    ICache iCache,
    DCache dCache,
    ROB rob,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    StoreForwardBuf#(16) committedStoreBuf
);
  action
    let entry = memExecEntry;
    Addr vaddr = memVaddr;
    Addr paddr = memPaddr;
    Bit#(5) cacheOp = fromMaybe(0, entry.cacheOp);
    Bool isCacop = (entry.iType == Cacop);
    if (isCacop && cacheOp[2:0] == 3'b000) begin
      iCache.cacop(cacheOp, vaddr, paddr);
      memState <= MemCacopIWait;
    end else begin
      MmuAccessType accessType = entry.isStore ? MmuStore : MmuLoad;
      Bool memUseCache = matUseCache(Direct, Cc, csrf.crmd, accessType);
      if (entry.iType == St) begin
        ByteMask m = fromMaybe(5'b00000, entry.mask);
        let storePkt = selectStoreData(entry.vk, vaddr[1:0], m[3:0]);
        storeBuf.enq(StoreBufEntry{
          addr: vaddr, data: tpl_2(storePkt),
          byteEn: extend(tpl_1(storePkt))
        });
        rob.updateMemInfo(entry.robTag, vaddr, paddr, memUseCache, entry.mask);
        rob.updateMem(entry.robTag, RobCompleted);
        memRS.remove(entry.robTag);
        memState <= MemIdle;
      end else begin
        Bit#(WordSz) byteEn = 4'b0000;
        Data wData = 0;
        MemOp memOp = Ld;
        if (entry.isLoad) begin
          memOp = (entry.iType == Ll) ? Ll : Ld;
        end else if (entry.iType == Sc) begin
          ByteMask m = fromMaybe(5'b00000, entry.mask);
          let storePkt = selectStoreData(entry.vk, vaddr[1:0], m[3:0]);
          byteEn = tpl_1(storePkt); wData = tpl_2(storePkt); memOp = Sc;
        end else if (coreIsBarrier(entry.iType)) begin
          memOp = Barrier;
        end else if (isCacop) begin
          memOp = Cacop;
        end
        let cacheReq = MemReq{
          op: memOp, addr: vaddr, paddr: paddr,
          useCache: (memOp == Cacop || memOp == Barrier) ? True : memUseCache,
          data: wData, byteEn: byteEn,
            size: memByteEnToAxiSize(truncate(fromMaybe(5'b0, entry.mask))),
          cacheOp: isCacop ? cacheOp : 5'b0
        };
        memForward <= entry.isLoad ?
          mergeForward(committedStoreBuf.forward(vaddr), storeBuf.forward(vaddr)) :
          StoreForwardResult{data: 0, byteEn: 0};
        rob.updateMemInfo(entry.robTag, vaddr, paddr, memUseCache, entry.mask);
        if (entry.iType == Ld && !memUseCache && entry.robTag != rob.headTag) begin
          memState <= MemUncacheWait;
        end else begin
          if (memOp == Cacop) dCache.cacop(cacheReq);
          else dCache.req(cacheReq);
          memState <= MemCacheWait;
        end
      end
    end
  endaction
endfunction

function Action doIssueMemUncacheBody(
    Reg#(MemExecState) memState,
    Reg#(RSEntry) memExecEntry,
    Reg#(Addr) memVaddr,
    Reg#(Addr) memPaddr,
    Reg#(StoreForwardResult) memForward,
    DCache dCache,
    StoreBuf#(16) storeBuf,
    StoreForwardBuf#(16) committedStoreBuf
);
  action
    let entry = memExecEntry;
    Addr vaddr = memVaddr;
    ByteMask mask = fromMaybe(5'b0, entry.mask);
    memForward <= mergeForward(committedStoreBuf.forward(vaddr), storeBuf.forward(vaddr));
    dCache.req(MemReq{
      op: Ld, addr: vaddr, paddr: memPaddr, useCache: False,
      data: 0, byteEn: 0,
      size: memByteEnToAxiSize(truncate(mask)), cacheOp: 0
    });
    memState <= MemCacheWait;
  endaction
endfunction

function Action doCollectMemCacheBody(
    Reg#(MemExecState) memState,
    Reg#(RSEntry) memExecEntry,
    Reg#(Addr) memVaddr,
    Reg#(StoreForwardResult) memForward,
    DCache dCache,
    CDB cdb,
    ROB rob,
    ResStation#(16) memRS
);
  action
    let d <- dCache.resp;
    let entry = memExecEntry;
    memState <= MemIdle;

    if (entry.isLoad) begin
      ByteMask m = fromMaybe(5'b00000, entry.mask);
      StoreForwardResult fwd = memForward;
      Data rawData = coreApplyByteMask(d.data, fwd.data, truncate(fwd.byteEn));
      Data loadData = ?;
      if (entry.iType == Ll)
        loadData = rawData;
      else
        loadData = selectLoadData(rawData, memVaddr[1:0], m[3:0], m[4] == 1'b1);
      if (entry.pDst matches tagged Valid .pd) begin
        cdb.sendLoad(pd, loadData);
      end
      rob.updateMem(entry.robTag, RobCompleted);
    end else if (entry.iType == Sc) begin
      if (entry.pDst matches tagged Valid .pd) begin
        cdb.sendLoad(pd, d.data);
      end
      rob.updateMem(entry.robTag, RobCompleted);
    end else begin
      // Dbar, Cacop: no PRF write
      rob.updateMem(entry.robTag, RobCompleted);
    end
    memRS.remove(entry.robTag);
  endaction
endfunction

function Action doCollectMemCacopIBody(
    Reg#(MemExecState) memState,
    Reg#(RSEntry) memExecEntry,
    ICache iCache,
    ROB rob,
    ResStation#(16) memRS
);
  action
    let done <- iCache.cacopResp;
    let entry = memExecEntry;
    memState <= MemIdle;
    rob.updateMem(entry.robTag, RobCompleted);
    memRS.remove(entry.robTag);
  endaction
endfunction

function Action doCollectMemIbarBody(
    Reg#(MemExecState) memState,
    Reg#(RSEntry) memExecEntry,
    ICache iCache,
    ROB rob,
    ResStation#(16) memRS
);
  action
    let done <- iCache.invalidateResp;
    let entry = memExecEntry;
    memState <= MemIdle;
    rob.updateMem(entry.robTag, RobCompleted);
    memRS.remove(entry.robTag);
  endaction
endfunction

endpackage
