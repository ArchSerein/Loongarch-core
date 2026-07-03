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
import AxiTypes::*;
import AxiMem::*;
import CoreTypes::*;
import CoreFunc::*;
import BranchPredictor::*;
import BranchPredTypes::*;
import OoOTypes::*;
import PRF::*;
import RAT::*;
import FreeList::*;
import ROB::*;
import ResStation::*;
import CDB::*;
import StoreBuf::*;

import Ifetch::*;
import Idecode::*;

`include "Autoconf.bsv"
`ifdef CONFIG_VSIM
`define CONFIG_WB_DEBUG
`define CONFIG_WB_DEBUG_INST
`endif
`ifdef CONFIG_FPGA
`define CONFIG_WB_DEBUG
`endif
`include "CsrAddr.bsv"
`ifdef CONFIG_DIFFTEST
import DiffTypes::*;
import Difftest::*;
`endif

typedef enum {
  CommitIdle,
  CommitReady,
  CommitTLBWait
} CommitState deriving(Bits, Eq);

(* synthesize *)
module mkCore(Core);
  // PC register: port[0]=IF1, port[1]=EX mispredict, port[2]=CM exception/ertn
  Ehr#(3, Addr)         pcReg <- mkEhr(startpc);
  CsrFile                csrf <- mkCsrFile;

  // OoO structures
  PRF                     prf <- mkPRF;
  RAT                     rat <- mkRAT;
  FreeList           freeList <- mkFreeList;
  ROB                     rob <- mkROB;
  CDB                     cdb <- mkCDB;
  ResStation#(16)      aluRS <- mkResStation;
  ResStation#(4)   muldivRS <- mkResStation;
  ResStation#(16)      memRS <- mkResStation;
  StoreBuf#(16)     storeBuf <- mkStoreBuf;

  // Shadow ARF for Difftest and debug
  Vector#(32, Reg#(Data)) archRegs <- replicateM(mkReg(0));

`ifdef CONFIG_DIFFTEST
  Difftest           difftest <- mkDifftest;
`endif

  // Caches, TLB, functional units
  ICache               iCache <- mkICache;
  DCache               dCache <- mkDCache;
  Mul_ifc             mulUnit <- mkMul;
  Div_ifc             divUnit <- mkDiv;
  AxiMemMaster        axiMux <- mkAxiArbiter2(iCache.axiMem, dCache.axiMem);
  BranchPredictor  branchPred <- mkBranchPredictor;
  TlbArray                tlb <- mkTlb;

  // Execution state
  Reg#(Bool)         aluBusy <- mkReg(False);
  Reg#(RSEntry)   aluExecEntry <- mkRegU;

  Reg#(Bool)     mulInFlight <- mkReg(False);
  Reg#(RSEntry)  mulExecEntry <- mkRegU;

  Reg#(Bool)     divInFlight <- mkReg(False);
  Reg#(RSEntry)  divExecEntry <- mkRegU;

  Reg#(MemExecState) memState <- mkReg(MemIdle);
  Reg#(RSEntry)   memExecEntry <- mkRegU;
  Reg#(Addr)        memVaddr  <- mkRegU;
  Reg#(Addr)        memPaddr  <- mkRegU;

  // Commit state
  Reg#(CommitState) commitState <- mkReg(CommitIdle);
  Reg#(DiffArchCsrState) csrSnapReg <- mkRegU;
  Reg#(Bit#(64)) stableCounterReg <- mkReg(0);

  Reg#(Bool)         idleLock <- mkReg(False);

  // I-Cache miss tracking
  Reg#(Bool)        if2WaitRefill <- mkReg(False);
  Reg#(F1toF2)       if2PendingReq <- mkRegU;
  Reg#(Addr)         if2MissPaddr  <- mkRegU;

  // Pipeline FIFOs
  Fifo#(2, F1toF2)       f1f2Fifo <- mkCFFifo;
  Fifo#(2, F2D)            f2dFifo <- mkCFFifo;
  Fifo#(2, D2R)            d2rnFifo <- mkCFFifo;
  Fifo#(2, RenamedInst)   rn2diFifo <- mkCFFifo;

`ifdef CONFIG_BSIM
  Fifo#(2, CpuToHostData) toHostFifo <- mkCFFifo;
`endif

`ifdef CONFIG_WB_DEBUG
  Wire#(Bool)       debugBreakPoint <- mkDWire(False);
  Wire#(Bool)       debugInforFlag <- mkDWire(False);
  Wire#(RIndx)      debugRegNum <- mkDWire(0);
  Wire#(Bool)       debugWsValidWire <- mkDWire(False);
  Wire#(Addr)       debugWbPcWire <- mkDWire(0);
  Wire#(Bit#(4))    debugWbRfWenWire <- mkDWire(0);
  Wire#(RIndx)      debugWbRfWnumWire <- mkDWire(0);
  Wire#(Data)       debugWbRfWdataWire <- mkDWire(0);
`ifdef CONFIG_WB_DEBUG_INST
  Wire#(Instruction) debugWbInstWire <- mkDWire(0);
`endif
`endif

  // ============================================================
  // IF1 Stage (unchanged)
  // ============================================================
  rule releaseIdleOnInterrupt (idleLock && csrf.interruptDetected);
    idleLock <= False;
  endrule

  rule doIF1NoFetchTlb (!idleLock && !if2WaitRefill && !f1f2Fifo.notEmpty &&
      getMmuTranslateType(csrf.crmd) != Translate);
    doIF1Body(pcReg[0], csrf.crmd, csrf.asid, csrf.dmw0, csrf.dmw1, getMmuTranslateType(csrf.crmd),
              branchPred, iCache, f1f2Fifo, pcReg[0]);
  endrule

  rule doIF1WithFetchTlb (!idleLock && !if2WaitRefill && !f1f2Fifo.notEmpty &&
      getMmuTranslateType(csrf.crmd) == Translate);
    Addr pc = pcReg[0];
    Data asid = csrf.asid;
    tlb.fetchLookupReq(pc, asid);
    doIF1Body(pc, csrf.crmd, asid, csrf.dmw0, csrf.dmw1, Translate,
              branchPred, iCache, f1f2Fifo, pcReg[0]);
  endrule

  // ============================================================
  // IF2 Stage (unchanged)
  // ============================================================
  rule doIF2if2WaitRefill (if2WaitRefill);
    let req = if2PendingReq;
    let iResp <- iCache.refillResp;
    if (iResp.addr == if2MissPaddr) begin
      f2dFifo.enq(F2D{
        pc: req.pc,
        predPc: req.predPc,
        inst: iResp.inst,
        instPaddr: if2MissPaddr,
        excp: mkNoExcp
      });
      if2WaitRefill <= False;
      pcReg[0] <= req.predPc;
    end
  endrule

  rule doIF2NoFetchTlb (!if2WaitRefill &&
      f1f2Fifo.first.transType != Translate);
    doIF2Body(noTlbLookup, f1f2Fifo, f2dFifo, iCache, if2PendingReq, if2MissPaddr, if2WaitRefill);
  endrule

  rule doIF2WithFetchTlb (!if2WaitRefill &&
      f1f2Fifo.first.transType == Translate);
    let tlbRes <- tlb.fetchLookupResp;
    doIF2Body(tlbRes, f1f2Fifo, f2dFifo, iCache, if2PendingReq, if2MissPaddr, if2WaitRefill);
  endrule

  // ============================================================
  // ID Stage (modified: d2rFifo -> d2rnFifo)
  // ============================================================
  rule doDecode;
    doDecodeBody(f2dFifo, d2rnFifo);
  endrule

  // ============================================================
  // RN Stage: Rename — RAT lookup, FreeList alloc, ROB enq
  // ============================================================
  rule doRename (!idleLock &&
      d2rnFifo.notEmpty && rn2diFifo.notFull && rob.notFull && freeList.notEmpty);
    let r = d2rnFifo.first;
    d2rnFifo.deq;

    DecodedInst dInst = r.dInst;
    ExcpInfo excp = r.excp;

    // Query RAT for source physical registers
    PIndx pSrc1 = 0;
    PIndx pSrc2 = 0;
    if (dInst.src1 matches tagged Valid .s1) pSrc1 = rat.lookup(s1);
    if (dInst.src2 matches tagged Valid .s2) pSrc2 = rat.lookup(s2);

    // Allocate destination physical register
    PIndx pDst = 0;
    PIndx oldPdst = 0;
    Maybe#(RIndx) normDst = normalizeReg(dInst.dst);
    if (!excp.valid &&& normDst matches tagged Valid .d) begin
      pDst = freeList.first;
      freeList.deq;
      oldPdst = rat.lookup(d);
      rat.update(d, pDst);
      prf.clearReady(pDst);
    end

    IType iType = dInst.iType;
    Bool brFlag = isBranch(iType);

    RobTag robTag = rob.enqTag;
    rob.enq(RobEntry{
      valid: True,
      state: RobIssued,
      pc: r.pc,
      inst: r.inst,
      pDst: (pDst == 0) ? tagged Invalid : tagged Valid pDst,
      oldPdst: (oldPdst == 0) ? tagged Invalid : tagged Valid oldPdst,
      dst: normDst,
      pSrc1: pSrc1,
      pSrc2: pSrc2,
      iType: iType,
      excp: excp,
      isBranch: brFlag,
      isStore: isStore(iType),
      isCsr: isCsr(iType),
      isTlb: isTlb(iType),
      isSpecial: isSpecial(iType),
      mispredict: False,
      correctTarget: r.pc + 4,
      memVaddr: 0,
      memPaddr: 0
    });

    if (brFlag) rat.checkpoint(robTag);

    rn2diFifo.enq(RenamedInst{
      pc: r.pc,
      predPc: r.predPc,
      inst: r.inst,
      dInst: dInst,
      pSrc1: pSrc1,
      pSrc2: pSrc2,
      pDst: pDst,
      oldPdst: oldPdst,
      robTag: robTag,
      isBranch: brFlag,
      excp: excp
    });
  endrule

  // ============================================================
  // DI Stage: Dispatch to RS based on instruction type
  // ============================================================
  // Helper: classify dispatch target
  function Bool dispIsAlu(RenamedInst r);
    return !r.excp.valid && !isCsrTlbSpecial(r.dInst.iType) &&
           (isAlu(r.dInst.iType) || isBranch(r.dInst.iType));
  endfunction
  function Bool dispIsMul(RenamedInst r);
    return !r.excp.valid && !isCsrTlbSpecial(r.dInst.iType) && isMulDiv(r.dInst.muldivFunc);
  endfunction
  function Bool dispIsMem(RenamedInst r);
    return !r.excp.valid && !isCsrTlbSpecial(r.dInst.iType) && isMem(r.dInst.iType);
  endfunction
  function Bool dispIsSpecial(RenamedInst r);
    return r.excp.valid || isCsrTlbSpecial(r.dInst.iType);
  endfunction

  rule doDispatchAlu (rn2diFifo.notEmpty && dispIsAlu(rn2diFifo.first));
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
    let entry = RSEntry{
      valid: True, iType: rInst.dInst.iType,
      aluFunc: rInst.dInst.aluFunc, muldivFunc: rInst.dInst.muldivFunc,
      brFunc: rInst.dInst.brFunc,
      qj: prf.isReady(rInst.pSrc1) ? tagged Invalid : tagged Valid rInst.pSrc1,
      qk: prf.isReady2(rInst.pSrc2) ? tagged Invalid : tagged Valid rInst.pSrc2,
      vj: prf.rd1(rInst.pSrc1), vk: prf.rd2(rInst.pSrc2),
      pDst: (rInst.pDst == 0) ? tagged Invalid : tagged Valid rInst.pDst,
      robTag: rInst.robTag,
      imm: rInst.dInst.imm, pc: rInst.pc, predPc: rInst.predPc,
      mask: rInst.dInst.mask, cacheOp: rInst.dInst.cacheOp,
      isStore: False, isLoad: False
    };
    aluRS.enq(entry);
  endrule

  rule doDispatchMulDiv (rn2diFifo.notEmpty && dispIsMul(rn2diFifo.first));
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
    let entry = RSEntry{
      valid: True, iType: rInst.dInst.iType,
      aluFunc: rInst.dInst.aluFunc, muldivFunc: rInst.dInst.muldivFunc,
      brFunc: rInst.dInst.brFunc,
      qj: prf.isReady(rInst.pSrc1) ? tagged Invalid : tagged Valid rInst.pSrc1,
      qk: prf.isReady2(rInst.pSrc2) ? tagged Invalid : tagged Valid rInst.pSrc2,
      vj: prf.rd1(rInst.pSrc1), vk: prf.rd2(rInst.pSrc2),
      pDst: (rInst.pDst == 0) ? tagged Invalid : tagged Valid rInst.pDst,
      robTag: rInst.robTag,
      imm: rInst.dInst.imm, pc: rInst.pc, predPc: rInst.predPc,
      mask: rInst.dInst.mask, cacheOp: rInst.dInst.cacheOp,
      isStore: False, isLoad: False
    };
    muldivRS.enq(entry);
  endrule

  rule doDispatchMem (rn2diFifo.notEmpty && dispIsMem(rn2diFifo.first));
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
    Bool isSt = isStore(rInst.dInst.iType);
    Bool isLd = isLoad(rInst.dInst.iType);
    let entry = RSEntry{
      valid: True, iType: rInst.dInst.iType,
      aluFunc: rInst.dInst.aluFunc, muldivFunc: rInst.dInst.muldivFunc,
      brFunc: rInst.dInst.brFunc,
      qj: prf.isReady(rInst.pSrc1) ? tagged Invalid : tagged Valid rInst.pSrc1,
      qk: prf.isReady2(rInst.pSrc2) ? tagged Invalid : tagged Valid rInst.pSrc2,
      vj: prf.rd1(rInst.pSrc1), vk: prf.rd2(rInst.pSrc2),
      pDst: (rInst.pDst == 0) ? tagged Invalid : tagged Valid rInst.pDst,
      robTag: rInst.robTag,
      imm: rInst.dInst.imm, pc: rInst.pc, predPc: rInst.predPc,
      mask: rInst.dInst.mask, cacheOp: rInst.dInst.cacheOp,
      isStore: isSt, isLoad: isLd
    };
    memRS.enq(entry);
  endrule

  rule doDispatchSpecial (rn2diFifo.notEmpty && dispIsSpecial(rn2diFifo.first));
    // CSR/TLB/special/exception: not dispatched to RS, just pass through
    let rInst = rn2diFifo.first;
    rn2diFifo.deq;
  endrule

  // ============================================================
  // CDB: Wakeup RS entries and writeback to PRF
  // ============================================================
  rule wakeupOnCDB (cdb.valid);
    let msg = cdb.msg;
    aluRS.wakeup(msg);
    muldivRS.wakeup(msg);
    memRS.wakeup(msg);
  endrule

  rule writebackToPRF (cdb.valid);
    let msg = cdb.msg;
    prf.cdbWrite(msg.tag, msg.value);
    prf.setReady(msg.tag);
  endrule

  // ============================================================
  // IS/EX Stage: ALU issue and execute
  // ============================================================
  rule doIssueALU (!aluBusy && !isCsrTlbSpecial(rob.headIType) &&&
      aluRS.selectOldestReady matches tagged Valid .entry);
    aluExecEntry <= entry;
    aluRS.remove(entry.robTag);
    aluBusy <= True;
  endrule

  rule doExecALU (aluBusy);
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
      pcReg[1] <= eInst.targetAddr;
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
      rat.restoreFromRetirement;
      freeList.clear;

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
  endrule

  // ============================================================
  // IS/EX Stage: MulDiv issue and collect
  // ============================================================
  function Bool isMulFunc(MulDivFunc f);
    return f == MulW || f == MulhW || f == MulhWu;
  endfunction
  function Bool isDivFunc(MulDivFunc f);
    return f == DivW || f == DivWu || f == ModW || f == ModWu;
  endfunction

  rule doIssueMul (!mulInFlight && !isCsrTlbSpecial(rob.headIType) &&&
      muldivRS.selectOldestReady matches tagged Valid .entry &&&
      isMulFunc(fromMaybe(?, entry.muldivFunc)));
    let mdFunc = fromMaybe(?, entry.muldivFunc);
    Bool is_signed = (mdFunc == MulW || mdFunc == MulhW || mdFunc == MulhWu);
    mulUnit.start(is_signed, entry.vj, entry.vk);
    mulExecEntry <= entry;
    muldivRS.remove(entry.robTag);
    mulInFlight <= True;
  endrule

  rule doIssueDiv (!divInFlight && !isCsrTlbSpecial(rob.headIType) &&&
      muldivRS.selectOldestReady matches tagged Valid .entry &&&
      isDivFunc(fromMaybe(?, entry.muldivFunc)));
    let mdFunc = fromMaybe(?, entry.muldivFunc);
    Bool is_signed = (mdFunc == DivW || mdFunc == DivWu || mdFunc == ModW || mdFunc == ModWu);
    divUnit.start(is_signed, entry.vj, entry.vk);
    divExecEntry <= entry;
    muldivRS.remove(entry.robTag);
    divInFlight <= True;
  endrule

  rule doCollectMul (mulInFlight && mulUnit.finish);
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
    rob.update(entry.robTag, RobCompleted);
  endrule

  rule doCollectDiv (divInFlight && divUnit.finish);
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
    rob.update(entry.robTag, RobCompleted);
  endrule

  // ============================================================
  // IS/EX Stage: Memory issue and collect
  // ============================================================
  Reg#(Bool) memNeedTlb <- mkReg(False);

  rule doIssueMem (memState == MemIdle && !isCsrTlbSpecial(rob.headIType) &&&
      memRS.selectOldestReady matches tagged Valid .entry);
    Data immVal = fromMaybe(0, entry.imm);
    Addr vaddr = entry.vj + immVal;
    ExcpInfo excp = checkMemHasExcp(entry.mask, vaddr, mkNoExcp);

    if (excp.valid) begin
      rob.updateExcp(entry.robTag, excp);
      rob.update(entry.robTag, RobCompleted);
      memRS.remove(entry.robTag);
    end else if (entry.iType == St) begin
      ByteMask m = fromMaybe(5'b00000, entry.mask);
      let storePkt = selectStoreData(entry.vk, vaddr[1:0], m[3:0]);
      storeBuf.enq(StoreBufEntry{
        addr: vaddr, data: tpl_2(storePkt),
        byteEn: extend(tpl_1(storePkt))
      });
      rob.updateMemInfo(entry.robTag, vaddr, vaddr);
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
  endrule

  rule doCollectMemTLB (memState == MemTLBWait && memNeedTlb);
    let tlbRes <- tlb.dataLookupResp;
    let entry = memExecEntry;
    Addr vaddr = memVaddr;
    MmuAccessType accessType = (entry.isStore || entry.iType == Sc) ? MmuStore : MmuLoad;
    MmuResult dTrans = mmuTranslate(vaddr, accessType, csrf.crmd, csrf.asid,
      csrf.dmw0, csrf.dmw1, tlbRes);
    if (dTrans.excValid) begin
      ExcpInfo memExcp = mkExcp(dTrans.ecode, dTrans.esubcode, dTrans.badv);
      rob.updateExcp(entry.robTag, memExcp);
      rob.update(entry.robTag, RobCompleted);
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
        Bool memUseCache = matUseCache(Translate, dTrans.mat, csrf.crmd, accessType);
        let cacheReq = MemReq{
          op: memOp, addr: vaddr, paddr: dTrans.pa,
          useCache: (memOp == Cacop || memOp == Barrier) ? True : memUseCache,
          data: wData, byteEn: byteEn,
          cacheOp: isCacop ? cacheOp : 5'b0
        };
        if (memOp == Cacop) dCache.cacop(cacheReq);
        else dCache.req(cacheReq);
        rob.updateMemInfo(entry.robTag, vaddr, dTrans.pa);
        memState <= MemCacheWait;
      end
    end
  endrule

  rule doCollectMemDirect (memState == MemTLBWait && !memNeedTlb);
    let entry = memExecEntry;
    Addr vaddr = memVaddr;
    Addr paddr = memPaddr;
    Bit#(5) cacheOp = fromMaybe(0, entry.cacheOp);
    Bool isCacop = (entry.iType == Cacop);
    if (isCacop && cacheOp[2:0] == 3'b000) begin
      iCache.cacop(cacheOp, vaddr, paddr);
      memState <= MemCacopIWait;
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
        useCache: True, data: wData, byteEn: byteEn,
        cacheOp: isCacop ? cacheOp : 5'b0
      };
      if (memOp == Cacop) dCache.cacop(cacheReq);
      else dCache.req(cacheReq);
      rob.updateMemInfo(entry.robTag, vaddr, paddr);
      memState <= MemCacheWait;
    end
  endrule

  rule doCollectMemCache (memState == MemCacheWait);
    let d <- dCache.resp;
    let entry = memExecEntry;
    memState <= MemIdle;

    if (entry.isLoad) begin
      ByteMask m = fromMaybe(5'b00000, entry.mask);
      Data loadData = ?;
      if (entry.iType == Ll)
        loadData = d.data;
      else
        loadData = selectLoadData(d.data, memVaddr[1:0], m[3:0], m[4] == 1'b1);
      if (entry.pDst matches tagged Valid .pd) begin
        cdb.sendLoad(pd, loadData);
      end
      rob.update(entry.robTag, RobCompleted);
    end else if (entry.iType == Sc) begin
      if (entry.pDst matches tagged Valid .pd) begin
        cdb.sendLoad(pd, d.data);
      end
      rob.update(entry.robTag, RobCompleted);
    end else begin
      // Dbar, Cacop: no PRF write
      rob.update(entry.robTag, RobCompleted);
    end
    memRS.remove(entry.robTag);
  endrule

  rule doCollectMemCacopI (memState == MemCacopIWait);
    let done <- iCache.cacopResp;
    let entry = memExecEntry;
    memState <= MemIdle;
    rob.update(entry.robTag, RobCompleted);
    memRS.remove(entry.robTag);
  endrule

  // ============================================================
  // CM Stage: Commit
  // ============================================================
  rule doCollectCommitTLB (commitState == CommitTLBWait);
    let res <- tlb.resp;
    commitState <= CommitIdle;
    let head = rob.head;

`ifdef CONFIG_DIFFTEST
    DiffArchCsrState diffCsrSnap = csrSnapReg;
`endif

    if (!head.excp.valid) begin
      if (head.iType == Tlbsrch) begin
        Data srchResult = 0;
        if (res.ne) srchResult[`CSR_TLBIDX_NE] = 1'b1;
        else srchResult[`CSR_TLBIDX_INDEX] = res.ehi[`CSR_TLBIDX_INDEX];
        csrf.applyTlbsrchResult(srchResult);
      end else if (head.iType == Tlbrd) begin
        csrf.applyTlbrdResult(res.ne, res.ps, res.ehi, res.elo0, res.elo1, res.asid);
      end else if (head.iType == Tlbwr || head.iType == Tlbfill) begin
        csrf.commitTlbOp;
      end
    end

    rob.deq;
`ifdef CONFIG_DIFFTEST
    // Difftest for TLB commit
    DiffArchCsrState diffCsr = diffCsrSnap;
    if (head.iType == Tlbrd) begin
      diffCsr = diffSnapshotAfterTlbrdFromState(diffCsrSnap,
        res.ne, res.ps, res.ehi, res.elo0, res.elo1, res.asid);
    end
    Vector#(32, Data) gpr = ?;
    for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
    difftest.enqTrace(DiffTrace{
      commit: DiffCommit{
        valid: !head.excp.valid, pc: head.pc, nextPc: head.pc + 4,
        inst: head.inst, wen: False, wdest: 0, wdata: 0, skip: False,
        isTlbfill: !head.excp.valid && head.iType == Tlbfill,
        tlbfillIndex: 0
      },
      regs: DiffArchGRegState{gpr: gpr},
      csr: diffCsr,
      excp: DiffExcpEvent{excpValid: False, eret: False, interrupt: 0,
        exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
      store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
      load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
    });
`endif
`ifdef CONFIG_WB_DEBUG
    debugWsValidWire <= True;
    debugWbPcWire <= head.pc;
`endif
  endrule

  // Helper: look up CSR value from a DiffArchCsrState snapshot
  function Data csrRdFromSnapshot(DiffArchCsrState snap, CsrIndx idx);
    Data res = 0;
    case (idx)
      `CSR_CRMD: res = snap.crmd;
      `CSR_PRMD: res = snap.prmd;
      `CSR_EUEN: res = snap.euen;
      `CSR_ECFG: res = snap.ecfg;
      `CSR_ESTAT: res = snap.estat;
      `CSR_ERA: res = snap.era;
      `CSR_BADV: res = snap.badv;
      `CSR_EENTRY: res = snap.eentry;
      `CSR_TLBIDX: res = snap.tlbidx;
      `CSR_TLBEHI: res = snap.tlbehi;
      `CSR_TLBEL0: res = snap.tlbelo0;
      `CSR_TLBEL1: res = snap.tlbelo1;
      `CSR_ASID: res = snap.asid;
      `CSR_PGDL: res = snap.pgdl;
      `CSR_PGDH: res = snap.pgdh;
      `CSR_PGD: res = (snap.badv[31] == 1) ? snap.pgdh : snap.pgdl;
      `CSR_SAVE0: res = snap.save0;
      `CSR_SAVE1: res = snap.save1;
      `CSR_SAVE2: res = snap.save2;
      `CSR_SAVE3: res = snap.save3;
      `CSR_TID: res = snap.tid;
      `CSR_TCFG: res = snap.tcfg;
      `CSR_TVAL: res = snap.tval;
      `CSR_LLBCTL: res = snap.llbctl;
      `CSR_TLBRENTRY: res = snap.tlbrentry;
      `CSR_DMW0: res = snap.dmw0;
      `CSR_DMW1: res = snap.dmw1;
      default: res = 0;
    endcase
    return res;
  endfunction


  rule takeCsrSnapshot (rob.headValid && commitState == CommitIdle);
    csrSnapReg <= csrf.diffSnapshot;
    stableCounterReg <= csrf.stableCounterValue;
    commitState <= CommitReady;
  endrule

  rule doCommit (rob.headValid && commitState == CommitReady);
    let head = rob.head;
    Bool doDeq = False;
    Bool waitTlb = False;

    // Read CSR values before any commit-side CSR action in this rule.
    DecodedInst dInst = decode(head.inst);
    DiffArchCsrState diffCsrSnap = csrSnapReg;
    Bit#(64) stableCounter = stableCounterReg;
    CsrIndx csrIdxForRd = fromMaybe(0, dInst.csr);
    Data csrReadVal = csrRdFromSnapshot(diffCsrSnap, csrIdxForRd);
    Data tlbReqAsidVal = diffCsrSnap.asid;
    Bit#(5) tlbRdIndex = truncate(diffCsrSnap.tlbidx[`CSR_TLBIDX_INDEX]);
    Data tlbWrIdx = effectiveTlbIdxForWrite(diffCsrSnap.tlbidx, diffCsrSnap.estat);
    Data tlbWrEhi = diffCsrSnap.tlbehi;
    Data tlbWrElo0 = diffCsrSnap.tlbelo0;
    Data tlbWrElo1 = diffCsrSnap.tlbelo1;
    Bool llbctlKloVal = unpack(diffCsrSnap.llbctl[2]);

    // Unconditional PRF reads for commit-stage source operands
    // (must be outside if-else branches to avoid EHR port sharing)
    Data cmRVal1 = prf.rd3(head.pSrc1);
    Data cmRVal2 = prf.rd4(head.pSrc2);

`ifdef CONFIG_WB_DEBUG
    debugWsValidWire <= True;
    debugWbPcWire <= head.pc;
`ifdef CONFIG_WB_DEBUG_INST
    debugWbInstWire <= head.inst;
`endif
`endif

    if (head.excp.valid) begin
      // Exception at commit: flush and redirect
      Bit#(6) ecode = head.excp.ecode;
      Bit#(9) esubcode = head.excp.esubcode;
`ifdef CONFIG_BSIM
      Bool wb_finish_on_syscall = False;
      if (ecode == `ECODE_SYS && esubcode == 9'h001) begin
        wb_finish_on_syscall = True;
        $display("this syscall 0x11, finish simulation");
        toHostFifo.enq(CpuToHostData{c2hType: ExitCode, data: 16'b0});
      end
`endif
      Addr exEntry <- csrf.raiseException(ecode, esubcode, head.pc, head.excp.badv);
      pcReg[2] <= exEntry;
      doDeq = True;

      // Flush pipeline
      iCache.squash;
      tlb.squashReq;
      tlb.squashFetchLookup;
      tlb.squashDataLookup;
      dCache.squash(False);
      if2WaitRefill <= False;
      f1f2Fifo.clear;
      f2dFifo.clear;
      d2rnFifo.clear;
      rn2diFifo.clear;
      aluRS.clear;
      muldivRS.clear;
      memRS.clear;
      storeBuf.clear;
      rob.clear;
      rat.restoreFromRetirement;
      freeList.clear;
      aluBusy <= False;
      mulInFlight <= False;
      divInFlight <= False;
      memState <= MemIdle;

`ifdef CONFIG_DIFFTEST
      Vector#(32, Data) gpr = ?;
      for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
      DiffArchCsrState diffCsr = diffSnapshotAfterWriteFromState(diffCsrSnap,
        tagged Invalid, 0, True, ecode, esubcode, head.pc, head.excp.badv, False);
      difftest.enqTrace(DiffTrace{
        commit: DiffCommit{
          valid: False, pc: head.pc, nextPc: exEntry,
          inst: head.inst, wen: False, wdest: 0, wdata: 0, skip: False,
          isTlbfill: False, tlbfillIndex: 0
        },
        regs: DiffArchGRegState{gpr: gpr},
        csr: diffCsr,
        excp: DiffExcpEvent{excpValid: True, eret: False,
          interrupt: mkInterruptNo(diffCsr.estat),
          exception: zeroExtend(ecode),
          exceptionPC: head.pc, exceptionInst: head.inst},
        store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
        load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
      });
`endif
    end else if (isTlb(head.iType)) begin
      // TLB instruction: issue TLB request, wait for response
      Data rVal1 = cmRVal1;
      Data rVal2 = cmRVal2;
      TlbOp op = TlbOpSearch;
      if (head.iType == Tlbrd) op = TlbOpRead;
      else if (head.iType == Tlbwr) op = TlbOpWrite;
      else if (head.iType == Tlbfill) op = TlbOpFill;
      else if (head.iType == Invtlb) op = TlbOpInv;
      Data tlbReqAsid = (head.iType == Invtlb) ? rVal2 : tlbReqAsidVal;
      tlb.req(TlbReq{
        op: op,
        tlbidx: (head.iType == Tlbrd) ? zeroExtend(tlbRdIndex) : tlbWrIdx,
        invOp: truncate(fromMaybe(0, dInst.imm)),
        ehi: tlbWrEhi,
        elo0: tlbWrElo0,
        elo1: tlbWrElo1,
        asid: tlbReqAsid,
        va: rVal1
      });
      waitTlb = True;
    end else if (isCsr(head.iType)) begin
      // CSR instruction: execute at commit
      Data rVal1 = cmRVal1;
      Data rVal2 = cmRVal2;

      // Use pre-computed value method results (from top of doCommit)
      Data csrVal = ?;
      if (head.iType == RdTimeL) begin
        csrVal = truncate(stableCounter);
      end else if (head.iType == RdTimeH) begin
        csrVal = truncateLSB(stableCounter);
      end else begin
        csrVal = csrReadVal;
      end

      // 2. Compute Difftest snapshot (value method — before wr)
      Bool wen = False;
      Data wdata = csrVal;
      `ifdef CONFIG_DIFFTEST
      Vector#(32, Data) gpr = ?;
      for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
      if (head.dst matches tagged Valid .dst &&& dst != 0) begin
        gpr[dst] = csrVal;
        wen = True;
      end
      Maybe#(CsrIndx) diffCsrIdx = tagged Invalid;
      Data diffCsrVal = csrVal;
      if (head.iType == Csrw) begin
        diffCsrIdx = dInst.csr;
        diffCsrVal = rVal1;
      end else if (head.iType == Csrxchg) begin
        diffCsrIdx = dInst.csr;
        diffCsrVal = (csrVal & (~rVal2)) | (rVal1 & rVal2);
      end
      DiffArchCsrState diffCsr = diffSnapshotAfterWriteFromState(diffCsrSnap,
        diffCsrIdx, diffCsrVal, False, 0, 0, head.pc, 0, False);
      `endif

      // 3. CSR write (action method — after all value methods)
      if (head.iType == Csrw) begin
        csrf.wr(dInst.csr, rVal1);
      end else if (head.iType == Csrxchg) begin
        csrf.wr(dInst.csr, (csrVal & (~rVal2)) | (rVal1 & rVal2));
      end

      // 4. Write to PRF and shadow ARF
      if (head.dst matches tagged Valid .dst &&& dst != 0) begin
        if (head.pDst matches tagged Valid .pd) begin
          prf.commitWrite(pd, csrVal);
          prf.setReadyCommit(pd);
        end
        archRegs[dst] <= csrVal;
        rat.updateRet(dst, fromMaybe(?, head.pDst));
        if (head.oldPdst matches tagged Valid .old) begin
          freeList.enq(old);
        end
      end

      doDeq = True;

      `ifdef CONFIG_DIFFTEST
      difftest.enqTrace(DiffTrace{
        commit: DiffCommit{
          valid: True, pc: head.pc, nextPc: head.pc + 4,
          inst: head.inst, wen: wen, wdest: fromMaybe(0, head.dst),
          wdata: wdata, skip: False, isTlbfill: False, tlbfillIndex: 0
        },
        regs: DiffArchGRegState{gpr: gpr},
        csr: diffCsr,
        excp: DiffExcpEvent{excpValid: False, eret: False,
          interrupt: mkInterruptNo(diffCsr.estat),
          exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
        store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
        load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
      });
      `endif
    end else if (head.iType == Ertn) begin
      // ERTN: return from exception
      Bool clearLl = !llbctlKloVal;
      Addr era <- csrf.returnFromException;
      pcReg[2] <= era;
      doDeq = True;

      // Flush pipeline
      iCache.squash;
      tlb.squashReq;
      tlb.squashFetchLookup;
      tlb.squashDataLookup;
      dCache.squash(clearLl);
      if2WaitRefill <= False;
      f1f2Fifo.clear;
      f2dFifo.clear;
      d2rnFifo.clear;
      rn2diFifo.clear;
      aluRS.clear;
      muldivRS.clear;
      memRS.clear;
      storeBuf.clear;
      rob.clear;
      rat.restoreFromRetirement;
      freeList.clear;
      aluBusy <= False;
      mulInFlight <= False;
      divInFlight <= False;
      memState <= MemIdle;

`ifdef CONFIG_DIFFTEST
      Vector#(32, Data) gpr = ?;
      for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
      DiffArchCsrState diffCsr = diffSnapshotAfterWriteFromState(diffCsrSnap,
        tagged Invalid, 0, False, 0, 0, head.pc, 0, True);
      difftest.enqTrace(DiffTrace{
        commit: DiffCommit{
          valid: True, pc: head.pc, nextPc: era,
          inst: head.inst, wen: False, wdest: 0, wdata: 0, skip: False,
          isTlbfill: False, tlbfillIndex: 0
        },
        regs: DiffArchGRegState{gpr: gpr},
        csr: diffCsr,
        excp: DiffExcpEvent{excpValid: False, eret: True,
          interrupt: mkInterruptNo(diffCsr.estat),
          exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
        store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
        load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
      });
`endif
    end else if (head.iType == Idle) begin
      // IDLE: wait for interrupt
      idleLock <= True;
      pcReg[2] <= head.pc + 4;
      doDeq = True;

`ifdef CONFIG_DIFFTEST
      Vector#(32, Data) gpr = ?;
      for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
      DiffArchCsrState diffCsr = diffCsrSnap;
      difftest.enqTrace(DiffTrace{
        commit: DiffCommit{
          valid: True, pc: head.pc, nextPc: head.pc + 4,
          inst: head.inst, wen: False, wdest: 0, wdata: 0, skip: False,
          isTlbfill: False, tlbfillIndex: 0
        },
        regs: DiffArchGRegState{gpr: gpr},
        csr: diffCsr,
        excp: DiffExcpEvent{excpValid: False, eret: False,
          interrupt: mkInterruptNo(diffCsr.estat),
          exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
        store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
        load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
      });
`endif
    end else if (head.iType == Syscall || head.iType == Break) begin
      // Syscall/Break: raise exception
      Bit#(6) ecode = (head.iType == Syscall) ? `ECODE_SYS : `ECODE_BRK;
      Bit#(9) esubcode = `ESUBCODE_NONE;
`ifdef CONFIG_BSIM
      if (head.iType == Syscall) begin
        Bit#(9) syscallEsubcode = (head.inst[14:0] == 15'h11) ? 9'h001 : `ESUBCODE_NONE;
        esubcode = syscallEsubcode;
        if (esubcode == 9'h001) begin
          $display("this syscall 0x11, finish simulation");
          toHostFifo.enq(CpuToHostData{c2hType: ExitCode, data: 16'b0});
        end
      end
`endif
      Addr exEntry <- csrf.raiseException(ecode, esubcode, head.pc, head.pc);
      pcReg[2] <= exEntry;
      doDeq = True;

      // Flush pipeline
      iCache.squash;
      tlb.squashReq;
      tlb.squashFetchLookup;
      tlb.squashDataLookup;
      dCache.squash(False);
      if2WaitRefill <= False;
      f1f2Fifo.clear;
      f2dFifo.clear;
      d2rnFifo.clear;
      rn2diFifo.clear;
      aluRS.clear;
      muldivRS.clear;
      memRS.clear;
      storeBuf.clear;
      rob.clear;
      rat.restoreFromRetirement;
      freeList.clear;
      aluBusy <= False;
      mulInFlight <= False;
      divInFlight <= False;
      memState <= MemIdle;

`ifdef CONFIG_DIFFTEST
      Vector#(32, Data) gpr = ?;
      for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
      DiffArchCsrState diffCsr = diffSnapshotAfterWriteFromState(diffCsrSnap,
        tagged Invalid, 0, True, ecode, esubcode, head.pc, head.pc, False);
      difftest.enqTrace(DiffTrace{
        commit: DiffCommit{
          valid: False, pc: head.pc, nextPc: exEntry,
          inst: head.inst, wen: False, wdest: 0, wdata: 0, skip: False,
          isTlbfill: False, tlbfillIndex: 0
        },
        regs: DiffArchGRegState{gpr: gpr},
        csr: diffCsr,
        excp: DiffExcpEvent{excpValid: True, eret: False,
          interrupt: mkInterruptNo(diffCsr.estat),
          exception: zeroExtend(ecode),
          exceptionPC: head.pc, exceptionInst: head.inst},
        store: DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0},
        load: DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0}
      });
`endif
    end else if (head.state == RobCompleted) begin
      // Normal commit (ALU, Ld, MulDiv, St, etc.)
      if (head.isStore) begin
        // Store commit: write to D-Cache
        let sqEntry = storeBuf.first;
        storeBuf.deq;
        let storePkt = selectStoreData(sqEntry.data, sqEntry.addr[1:0], truncate(sqEntry.byteEn));
        dCache.req(MemReq{
          op: St, addr: sqEntry.addr, paddr: head.memPaddr,
          useCache: True,
          data: tpl_2(storePkt), byteEn: tpl_1(storePkt),
          cacheOp: 5'b0
        });
      end

      // Update shadow ARF and retRAT for register-writing instructions
      Bool wen = False;
      Data wdata = 0;
      if (head.dst matches tagged Valid .dst &&& dst != 0) begin
        if (head.pDst matches tagged Valid .pd) begin
          wdata = prf.rd5(pd);
        end
        archRegs[dst] <= wdata;
        rat.updateRet(dst, fromMaybe(?, head.pDst));
        if (head.oldPdst matches tagged Valid .old) begin
          freeList.enq(old);
        end
        wen = True;
      end

      // Handle Ll/Sc side effects
      if (head.iType == Ll) begin
        csrf.setLlbit(True);
      end else if (head.iType == Sc) begin
        csrf.setLlbit(False);
      end

      doDeq = True;

`ifdef CONFIG_DIFFTEST
      Vector#(32, Data) gpr = ?;
      for (Integer i = 0; i < 32; i = i + 1) gpr[i] = archRegs[i];
      if (head.dst matches tagged Valid .dst &&& dst != 0) begin
        gpr[dst] = wdata;
      end
      DiffArchCsrState diffCsr = diffCsrSnap;
      if (head.iType == Ll || head.iType == Sc) begin
        Data diffLlbctl = diffCsr.llbctl;
        diffLlbctl[0] = pack(head.iType == Ll);
        diffCsr.llbctl = diffLlbctl;
      end
      // Compute nextPc
      Addr commitNextPc = head.mispredict ? head.correctTarget : (head.pc + 4);
      // Store/load diff events
      Maybe#(DiffMemOp) diffMem = tagged Invalid;
      if (head.iType == Ld || head.iType == Ll) begin
        diffMem = tagged Valid DiffMemOp{
          isLoad: True, isStore: False, isSc: False,
          paddr: head.memPaddr, vaddr: head.memVaddr, storeData: 0
        };
      end else if (head.iType == St) begin
        let sqEntry = storeBuf.first;
        diffMem = tagged Valid DiffMemOp{
          isLoad: False, isStore: True, isSc: False,
          paddr: head.memPaddr, vaddr: head.memVaddr,
          storeData: sqEntry.data
        };
      end else if (head.iType == Sc) begin
        diffMem = tagged Valid DiffMemOp{
          isLoad: False, isStore: True, isSc: True,
          paddr: head.memPaddr, vaddr: head.memVaddr,
          storeData: wdata
        };
      end
      DiffStoreEvent storeEvent = diffStoreEventOf(diffMem, head.iType, ?, wdata);
      DiffLoadEvent loadEvent = diffLoadEventOf(diffMem, head.iType, ?);
      difftest.enqTrace(DiffTrace{
        commit: DiffCommit{
          valid: True, pc: head.pc, nextPc: commitNextPc,
          inst: head.inst, wen: wen, wdest: fromMaybe(0, head.dst),
          wdata: wdata, skip: False,
          isTlbfill: False, tlbfillIndex: 0
        },
        regs: DiffArchGRegState{gpr: gpr},
        csr: diffCsr,
        excp: DiffExcpEvent{excpValid: False, eret: False,
          interrupt: mkInterruptNo(diffCsr.estat),
          exception: 0, exceptionPC: head.pc, exceptionInst: head.inst},
        store: storeEvent,
        load: loadEvent
      });
`endif
    end else begin
      // Not completed: stall
    end

    if (waitTlb) begin
      commitState <= CommitTLBWait;
    end else begin
      commitState <= CommitIdle;
    end

    if (doDeq) rob.deq;
  endrule

  // ============================================================
  // Interface methods
  // ============================================================
  method Action setInterrupt(Bit#(8) val);
    csrf.setInterrupt(val);
  endmethod

`ifdef CONFIG_BSIM
  method ActionValue#(CpuToHostData) cpuToHost if (toHostFifo.notEmpty);
    let ret = toHostFifo.first;
    toHostFifo.deq;
    return ret;
  endmethod
  method Bool cpuToHostValid = toHostFifo.notEmpty;
  method Action hostToCpu(Addr startpc);
    noAction;
  endmethod
`endif

`ifdef CONFIG_DIFFTEST
  `ifdef CONFIG_BSIM
  method ActionValue#(DiffTrace) diffTrace;
    let ret <- difftest.diffTrace;
    return ret;
  endmethod
  method Bool diffTraceValid = difftest.diffTraceValid;
  `else
  method Bool diffStepValid = difftest.diffStepValid;
  method Bit#(142) liveDiffCommitBundle = difftest.liveDiffCommitBundle;
  method Bit#(1024) liveDiffRegsBundle = difftest.liveDiffRegsBundle;
  method Bit#(832) liveDiffCsrBundle = difftest.liveDiffCsrBundle;
  method Bit#(130) liveDiffExcpBundle = difftest.liveDiffExcpBundle;
  method Bit#(200) liveDiffStoreBundle = difftest.liveDiffStoreBundle;
  method Bit#(136) liveDiffLoadBundle = difftest.liveDiffLoadBundle;
  `endif
`endif

`ifdef CONFIG_WB_DEBUG
  method Action debugInput(Bool breakPoint, Bool inforFlag, RIndx regNum);
    debugBreakPoint <= breakPoint;
    debugInforFlag <= inforFlag;
    debugRegNum <= regNum;
  endmethod

  method Bool wsValid = debugWsValidWire;

  method Data rfRdata = debugInforFlag ? archRegs[debugRegNum] : 0;

  method Addr debug0WbPc = debugWbPcWire;

  method Bit#(4) debug0WbRfWen = debugWbRfWenWire;

  method RIndx debug0WbRfWnum = debugWbRfWnumWire;

  method Data debug0WbRfWdata = debugWbRfWdataWire;

`ifdef CONFIG_WB_DEBUG_INST
  method Instruction debug0WbInst = debugWbInstWire;
`endif
`endif

  interface axiMem = axiMux;
endmodule
