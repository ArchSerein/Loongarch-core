package Writeback;

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
import MemTypes::*;
import RFile::*;
import CsrFile::*;
import Scoreboard::*;
import ICache::*;
import DCache::*;
import Tlb::*;
import CoreFunc::*;
import CoreTypes::*;
`include "CsrAddr.bsv"
`ifdef CONFIG_DIFFTEST
import DiffTypes::*;
import Difftest::*;
`endif
`ifdef CONFIG_TRACE_PERFORMANCE
import Perf::*;
`endif

function Action doWritebackBody(
    Fifo#(2, M2W) m2wFifo,
    RFile rf,
    CsrFile csrf,
    Reg#(Addr) pcReg_2,
    Reg#(Bool) idleLock,
    ICache iCache,
    DCache dCache,
    TlbArray tlb,
    Scoreboard#(8) regSb,
    SFifo#(8, Maybe#(CsrIndx), Maybe#(CsrIndx)) csrSb,
    Reg#(Bool) memRedirectPending,
    Reg#(Bool) if2WaitRefill,
    Fifo#(2, F1toF2) f1f2Fifo,
    Fifo#(2, F2D) f2dFifo,
    Fifo#(2, D2R) d2rFifo,
    Fifo#(2, R2E) r2eFifo,
    Fifo#(2, E2M) e2mFifo,
    Fifo#(2, M1toM2) m1m2Fifo,
    Reg#(Bool) mulInFlight,
    Reg#(Bool) divInFlight
`ifdef CONFIG_DIFFTEST
    , Difftest difftest
`endif
`ifdef CONFIG_BSIM
    , Fifo#(2, CpuToHostData) toHostFifo
`endif
);
    action
    let memPkt = m2wFifo.first();
    Bool wbRetire = False;
    Bool wbFlush = False;
    Bool clearDCacheLlOnFlush = False;

    if (isValid(memPkt.mInst)) begin
      let mInst = fromMaybe(?, memPkt.mInst);
      Bool wbReady = True;
      Bool isCacop = (mInst.iType == Cacop);

      ExcpInfo wbExcp = memPkt.excp;
      Bool wb_finish_on_syscall = False;
      Bool has_int = memPkt.excp.valid && memPkt.excp.ecode == `ECODE_INT;
`ifdef CONFIG_BSIM
      wb_finish_on_syscall = (!has_int) && wbExcp.valid &&
        (wbExcp.ecode == `ECODE_SYS) && (wbExcp.esubcode == 9'h001);
`endif
      Bool wb_has_excp = wbExcp.valid && !wb_finish_on_syscall;
      Bit#(6) wb_ecode = wbExcp.ecode;
      Bit#(9) wb_esubcode = wbExcp.esubcode;
      Addr ertnTarget = 0;
      Bool wbNeedsFlush = wb_has_excp || ((!wb_has_excp) && mInst.iType == Ertn);
      Bit#(5) wbTlbfillIndex = 0;

      if (wbReady) begin
        Bool wen = False;
        Bool wbIsCsrWrite = (mInst.iType == Csrw || mInst.iType == Csrxchg);
`ifdef CONFIG_DIFFTEST
        let currDiffCsrState = memPkt.csrSnapshot;
`endif
        if (wb_has_excp) begin
          Addr exEntry <- csrf.raiseException(wb_ecode, wb_esubcode, memPkt.pc, wbExcp.badv);
          pcReg_2 <= exEntry;
          wbFlush = True;
        end else begin
`ifdef CONFIG_BSIM
          if (wb_finish_on_syscall) begin
            $display("this syscall 0x11, finish simulation");
            toHostFifo.enq(CpuToHostData{
              c2hType: ExitCode,
              data: 16'b0
            });
          end
`endif
          if (isValid(mInst.dst)) begin
            rf.wr(fromMaybe(?, mInst.dst), mInst.data);
            wen = (fromMaybe(0, mInst.dst) != 0);
          end
          if (mInst.iType == Ertn) begin
            Bool clearLl = !csrf.llbctlKloValue;
            Addr era <- csrf.returnFromException;
            if (clearLl) begin
              clearDCacheLlOnFlush = True;
            end
            ertnTarget = era;
            pcReg_2 <= era;
            wbFlush = True;
          end else if (mInst.iType == Idle) begin
            pcReg_2 <= memPkt.pc + 4;
            idleLock <= True;
            wbFlush = True;
          end else if (mInst.iType == Tlbfill) begin
            if (memPkt.tlbResult matches tagged Valid .tlbFillRes) begin
              wbTlbfillIndex = truncate(tlbFillRes.ehi[`CSR_TLBIDX_INDEX]);
            end
          end else if (mInst.iType == Ibar) begin
            iCache.invalidate;
          end else if (mInst.iType == Ll) begin
            csrf.setLlbit(True);
          end else if (mInst.iType == Sc) begin
            csrf.setLlbit(False);
          end else begin
            if (wbIsCsrWrite &&& mInst.csr matches tagged Valid .csrIdx &&&
                csrIdx == `CSR_LLBCTL && mInst.addr[1] == 1'b1) begin
              clearDCacheLlOnFlush = True;
            end
            csrf.wr(wbIsCsrWrite ? mInst.csr : Invalid, wbIsCsrWrite ? mInst.addr : mInst.data);
          end

          if (!wbFlush && memPkt.isNeedFlush) begin
            pcReg_2 <= memPkt.pc + 4;
            wbFlush = True;
          end
        end

`ifdef CONFIG_DIFFTEST
        Bool diffCommitErtn = (!wb_has_excp) && (mInst.iType == Ertn);
        Addr commitNextPc = diffCommitErtn ? ertnTarget : (mInst.mispredict ? mInst.addr : (memPkt.pc + 4));

        Maybe#(RIndx) diffDst = tagged Invalid;
        Maybe#(CsrIndx) diffCsrIdx = tagged Invalid;
        Data diffCsrVal = mInst.data;
        if (wen && isValid(mInst.dst)) begin
          diffDst = mInst.dst;
        end
        if (!wb_has_excp) begin
          if (mInst.iType == Tlbsrch) begin
            diffCsrIdx = tagged Valid `CSR_TLBIDX;
            diffCsrVal = csrf.tlbidx;
          end else if (mInst.iType == Csrw || mInst.iType == Csrxchg) begin
            diffCsrIdx = mInst.csr;
            diffCsrVal = mInst.addr;
          end
        end

        DiffStoreEvent storeEvent = !wb_has_excp ?
          diffStoreEventOf(memPkt.diffMem, mInst.iType, mInst.mask, mInst.data) :
          DiffStoreEvent{valid: 0, paddr: 0, vaddr: 0, data: 0};
        DiffLoadEvent loadEvent = !wb_has_excp ?
          diffLoadEventOf(memPkt.diffMem, mInst.iType, mInst.mask) :
          DiffLoadEvent{valid: 0, paddr: 0, vaddr: 0};

        let diffRegsState = rf.diffSnapshotAfterWrite(diffDst, mInst.data);

        DiffArchCsrState diffCsrState = diffSnapshotAfterWriteFromState(
          currDiffCsrState,
          diffCsrIdx,
          diffCsrVal,
          wb_has_excp,
          wb_ecode,
          wb_esubcode,
          memPkt.pc,
          wbExcp.badv,
          diffCommitErtn
          );
        if (mInst.iType == Tlbrd) begin
          if (memPkt.tlbResult matches tagged Valid .tlbRead) begin
            diffCsrState = diffSnapshotAfterTlbrdFromState(currDiffCsrState,
              tlbRead.ne, tlbRead.ps, tlbRead.ehi, tlbRead.elo0,
              tlbRead.elo1, tlbRead.asid);
          end
        end
        if (!wb_has_excp && (mInst.iType == Ll || mInst.iType == Sc)) begin
          Data diffLlbctl = diffCsrState.llbctl;
          diffLlbctl[0] = pack(mInst.iType == Ll);
          diffCsrState.llbctl = diffLlbctl;
        end

        let diffCommitState = DiffCommit{
          valid: !wb_has_excp,
          pc: memPkt.pc,
          nextPc: commitNextPc,
          inst: memPkt.inst,
          wen: wen,
          wdest: fromMaybe(0, mInst.dst),
          wdata: mInst.data,
          skip: False,
          isTlbfill: (!wb_has_excp) && (mInst.iType == Tlbfill),
          tlbfillIndex: wbTlbfillIndex
        };
        let diffExcpState = DiffExcpEvent{
          excpValid: wb_has_excp,
          eret: (mInst.iType == Ertn),
          interrupt: mkInterruptNo(diffCsrState.estat),
          exception: has_int ? 0 : zeroExtend(wbExcp.ecode),
          exceptionPC: memPkt.pc,
          exceptionInst: memPkt.inst
        };

        difftest.enqTrace(DiffTrace{
          commit: diffCommitState,
          regs: diffRegsState,
          csr: diffCsrState,
          excp: diffExcpState,
          store: storeEvent,
          load: loadEvent
        });
`endif
        `ifdef CONFIG_TRACE_PERFORMANCE
          if (!wb_has_excp) begin
            inst_count();
          end
        `endif
        if (!wbFlush) begin
          wbRetire = True;
        end
      end
    end else begin
      wbRetire = True;
    end

    // Pipeline Flush Logic: Clear all pipeline FIFOs, squash in-flight cache and TLB requests,
    // and reset stall signals when a branch misprediction or exception redirects control flow.
    if (wbFlush) begin
      iCache.squash();
      tlb.squashReq();
      tlb.squashFetchLookup();
      tlb.squashDataLookup();
      dCache.squash(clearDCacheLlOnFlush);
      memRedirectPending <= False;
      if2WaitRefill <= False;
      f1f2Fifo.clear();
      f2dFifo.clear();
      d2rFifo.clear();
      r2eFifo.clear();
      e2mFifo.clear();
      m1m2Fifo.clear();
      m2wFifo.clear();
      regSb.clear();
      csrSb.clear();
      mulInFlight <= False;
      divInFlight <= False;
    end else if (wbRetire) begin
      if (isValid(memPkt.mInst)) begin
        let retiredType = fromMaybe(?, memPkt.mInst).iType;
      end
      m2wFifo.deq();
      regSb.remove();
      csrSb.deq();
    end
    endaction
endfunction

endpackage
