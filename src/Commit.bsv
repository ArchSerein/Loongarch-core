package Commit;

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
import CsrFile::*;
import Mmu::*;
import Tlb::*;
import Fifo::*;
import Ehr::*;
import Vector::*;
import ICache::*;
import DCache::*;
import CoreTypes::*;
import CoreFunc::*;
import OoOTypes::*;
import PRF::*;
import RAT::*;
import FreeList::*;
import ROB::*;
import ResStation::*;
import StoreBuf::*;
import DiffTypes::*;
`ifdef CONFIG_DIFFTEST
import Difftest::*;
`endif

`include "CsrAddr.bsv"

function Action doCollectCommitTLBBody(
    Reg#(CommitState) commitState,
    TlbArray tlb,
    ROB rob,
    CsrFile csrf
`ifdef CONFIG_DIFFTEST
    , Reg#(DiffArchCsrState) csrSnapReg
    , Vector#(32, Reg#(Data)) archRegs
    , Difftest difftest
`endif
`ifdef CONFIG_WB_DEBUG
    , Wire#(Bool) debugWsValidWire
    , Wire#(Addr) debugWbPcWire
`endif
);
  action
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
  endaction
endfunction

function Action takeCsrSnapshotBody(
    Reg#(DiffArchCsrState) csrSnapReg,
    Reg#(Bit#(64)) stableCounterReg,
    CsrFile csrf,
    Reg#(CommitState) commitState
);
  action
    csrSnapReg <= csrf.diffSnapshot;
    stableCounterReg <= csrf.stableCounterValue;
    commitState <= CommitReady;
  endaction
endfunction

function Action doCommitBody(
    ROB rob,
    Reg#(CommitState) commitState,
    CsrFile csrf,
    Reg#(DiffArchCsrState) csrSnapReg,
    Reg#(Bit#(64)) stableCounterReg,
    PRF prf,
    RAT rat,
    FreeList freeList,
    TlbArray tlb,
    Reg#(Addr) pcReg,
    ICache iCache,
    DCache dCache,
    Reg#(Bool) if2WaitRefill,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2RN) d2rnFifo,
    Fifo#(2, RenamedInst) rn2diFifo,
    ResStation#(16) aluRS,
    ResStation#(4) muldivRS,
    ResStation#(16) memRS,
    StoreBuf#(16) storeBuf,
    Reg#(Bool) idleLock,
    Reg#(Bool) aluBusy,
    Reg#(Bool) mulInFlight,
    Reg#(Bool) divInFlight,
    Reg#(MemExecState) memState
`ifdef CONFIG_BSIM
    , Fifo#(2, CpuToHostData) toHostFifo
`endif
`ifdef CONFIG_DIFFTEST
    , Difftest difftest
    , Vector#(32, Reg#(Data)) archRegs
`endif
`ifdef CONFIG_WB_DEBUG
    , Wire#(Bool) debugWsValidWire
    , Wire#(Addr) debugWbPcWire
`ifdef CONFIG_WB_DEBUG_INST
    , Wire#(Instruction) debugWbInstWire
`endif
`endif
);
  action
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
    StoreBufEntry commitStoreEntry = ?;

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
      pcReg <= exEntry;
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
		`ifdef CONFIG_DIFFTEST
        archRegs[dst] <= csrVal;
		`endif
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
      pcReg <= era;
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
      pcReg <= head.pc + 4;
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
      pcReg <= exEntry;
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
        commitStoreEntry = storeBuf.first;
        storeBuf.deq;
        dCache.req(MemReq{
          op: St, addr: commitStoreEntry.addr, paddr: head.memPaddr,
          useCache: True,
          data: commitStoreEntry.data, byteEn: truncate(commitStoreEntry.byteEn),
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
		`ifdef CONFIG_DIFFTEST
        archRegs[dst] <= wdata;
		`endif
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
        diffMem = tagged Valid DiffMemOp{
          isLoad: False, isStore: True, isSc: False,
          paddr: head.memPaddr, vaddr: head.memVaddr,
          storeData: commitStoreEntry.data
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
  endaction
endfunction

endpackage
