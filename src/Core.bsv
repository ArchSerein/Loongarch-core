import Types::*;
import ProcTypes::*;
import MemTypes::*;
import RFile::*;
import Decode::*;
import Exec::*;
import CsrFile::*;
import Mmu::*;
import Tlb::*;
import Fifo::*;
import Ehr::*;
import Btb::*;
import Scoreboard::*;
import SFifo::*;
import Bht::*;
import Vector::*;
import ICache::*;
import DCache::*;
import Mul::*;
import Div::*;
import AxiTypes::*;
import AxiMem::*;
import CoreTypes::*;
import CoreFunc::*;

import Ifetch::*;
import Idecode::*;
import RegRead::*;
import Execute::*;
import CoreMemory::*;
import Writeback::*;

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
`ifdef CONFIG_TRACE_PERFORMANCE
import Perf::*;
`endif

(* synthesize *)
module mkCore(Core);
  Ehr#(3, Addr)         pcReg <- mkEhr(startpc);
  CsrFile                csrf <- mkCsrFile;
  RFile                    rf <- mkBypassRFile;
  // Cache and TLB Instantiations:
  // L1 Instruction Cache, L1 Data Cache, and TLB Array.
  // They interact with the MMU for address translation and the AXI bus for main memory access.
  ICache               iCache <- mkICache;
  DCache               dCache <- mkDCache;
  Mul_ifc             mulUnit <- mkMul;
  Reg#(Bool)      mulInFlight <- mkReg(False);
  Div_ifc             divUnit <- mkDiv;
  Reg#(Bool)      divInFlight <- mkReg(False);
  // AXI Bus Arbitration: Multiplexes memory requests from I-Cache and D-Cache to the main memory.
  AxiMemMaster        axiMux <- mkAxiArbiter2(iCache.axiMem, dCache.axiMem);
  Btb#(6)                 btb <- mkBtb; // 64-entry BTB
  Bht#(8)                 bht <- mkBht;
  Scoreboard#(8)        regSb <- mkCFScoreboard;
  SFifo#(8, Maybe#(CsrIndx), Maybe#(CsrIndx)) csrSb <- mkCFSFifo(coreIsCsrConflict);
  Reg#(Bool)         idleLock <- mkReg(False);
  TlbArray                tlb <- mkTlb;
`ifdef CONFIG_DIFFTEST
  Difftest difftest <- mkDifftest;
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

  // 7-stage pipeline FIFOs
  Fifo#(2, F1toF2)       f1f2Fifo <- mkCFFifo;  // IF1 -> IF2
  Fifo#(2, F2D)            f2dFifo <- mkCFFifo;  // IF2 -> ID
  Fifo#(2, D2R)            d2rFifo <- mkCFFifo;  // ID -> RR
  Fifo#(2, R2E)            r2eFifo <- mkCFFifo;  // RR -> EXE
  Fifo#(2, E2M)            e2mFifo <- mkCFFifo;  // EXE -> MEM
  Fifo#(2, M1toM2)        m1m2Fifo <- mkCFFifo;  // MEM1 -> MEM2
  Fifo#(2, M2W)            m2wFifo <- mkCFFifo;  // MEM -> WB

  // I-Cache miss tracking: IF2 waits for refill
  Reg#(Bool)        if2WaitRefill <- mkReg(False);
  Reg#(F1toF2)       if2PendingReq <- mkRegU;
  Reg#(Addr)         if2MissPaddr  <- mkRegU;

`ifdef CONFIG_BSIM
  Fifo#(2, CpuToHostData) toHostFifo <- mkCFFifo;
`endif
  Reg#(Bool) memRedirectPending <- mkReg(False);

  // ============================================================
  // Stage 1: IF1 — PC selection, start I-Cache probe, start I-TLB lookup
  // ============================================================
`ifdef CONFIG_TRACE_PERFORMANCE
  rule countIfStall (!f1f2Fifo.notFull);
    perf_pipeline_stall(0);
  endrule

  rule countExStall(!e2mFifo.notFull);
    perf_pipeline_stall(2);
  endrule
`endif

  rule releaseIdleOnInterrupt (idleLock && csrf.interruptDetected);
    idleLock <= False;
  endrule

  rule doIF1NoFetchTlb (!idleLock && getMmuTranslateType(csrf.crmd) != Translate);
    doIF1Body(pcReg[0], csrf.crmd, csrf.asid, csrf.dmw0, csrf.dmw1, getMmuTranslateType(csrf.crmd),
              btb, bht, iCache, f1f2Fifo, pcReg[0]);
  endrule

  rule doIF1WithFetchTlb (!idleLock && getMmuTranslateType(csrf.crmd) == Translate);
    Addr pc = pcReg[0];
    Data asid = csrf.asid;
    tlb.fetchLookupReq(pc, asid);
    doIF1Body(pc, csrf.crmd, asid, csrf.dmw0, csrf.dmw1, Translate,
              btb, bht, iCache, f1f2Fifo, pcReg[0]);
  endrule

  // ============================================================
  // Stage 2: IF2 — I-Cache tag match, instruction selection, I-MMU result
  // ============================================================
  rule doIF2if2WaitRefill (if2WaitRefill);
    let req = if2PendingReq;
    let iResp <- iCache.refillResp;
`ifdef CONFIG_TRACE_PERFORMANCE
    perf_icache_miss_cycle();
`endif
    if (iResp.addr == if2MissPaddr) begin
      f2dFifo.enq(F2D{
        pc: req.pc,
        predPc: req.predPc,
        inst: iResp.inst,
        instPaddr: if2MissPaddr,
        excp: mkNoExcp
      });
      if2WaitRefill <= False;
      f1f2Fifo.deq();
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
  // Stage 3: ID — Instruction decode, simple J/B resolution, scoreboard
  // ============================================================
  rule doDecode;
    doDecodeBody(f2dFifo, d2rFifo);
  endrule

  // ============================================================
  // Stage 4: RR — Register File read, CSR read, forwarding logic
  // ============================================================
  `ifdef CONFIG_TRACE_PERFORMANCE
  rule countRfStall (d2rFifo.notEmpty() && rrfHasHazard(d2rFifo.first(), regSb, csrSb));
    perf_pipeline_stall(1);
  endrule
  `endif

  rule doRrf (d2rFifo.notEmpty() && !rrfHasHazard(d2rFifo.first(), regSb, csrSb));
    doRrfBody(d2rFifo, r2eFifo, rf, csrf, regSb, csrSb);
  endrule

  // ============================================================
  // Stage 5: EXE — ALU, AGU, Mul/Div start, Branch resolution
  // D-MMU translation is REMOVED from this stage (moved to MEM)
  // ============================================================
  rule doExec;
    doExecBody(r2eFifo, e2mFifo, f1f2Fifo, f2dFifo, d2rFifo, pcReg[1], iCache, tlb, btb, bht, regSb, csrSb, if2WaitRefill, mulUnit, mulInFlight, divUnit, divInFlight, csrf);
  endrule

  // ============================================================
  // Stage 6a/6b: MEM1 dispatch and MEM2 response collection
  // ============================================================
`ifdef CONFIG_TRACE_PERFORMANCE
  rule countMemStall (e2mFifo.notEmpty && !m1m2Fifo.notFull);
    perf_pipeline_stall(3);
  endrule
`endif

  rule doMemoryStage1NoDataTlb (e2mFifo.notEmpty &&
      !e2mFifo.first.dataTlbLookupPending);
    doMemoryStage1Body(noTlbLookup, e2mFifo, m1m2Fifo, csrf, regSb, dCache, iCache, tlb, memRedirectPending);
  endrule

  rule doMemoryStage1WithDataTlb (e2mFifo.notEmpty &&
      e2mFifo.first.dataTlbLookupPending);
    let tlbRes <- tlb.dataLookupResp;
    doMemoryStage1Body(tlbRes, e2mFifo, m1m2Fifo, csrf, regSb, dCache, iCache, tlb, memRedirectPending);
  endrule

  rule doMemoryStage2NoResp (m1m2Fifo.notEmpty &&
      m1m2Fifo.first.m2Op == M2OpNone);
    doMemoryStage2Body(tagged Invalid, tagged Invalid, tagged Invalid, m1m2Fifo, m2wFifo, regSb, csrf);
  endrule

  rule doMemoryStage2DCache (m1m2Fifo.notEmpty &&
      m1m2Fifo.first.m2Op == M2OpDCache);
    let d <- dCache.resp();
    doMemoryStage2Body(tagged Valid d, tagged Invalid, tagged Invalid, m1m2Fifo, m2wFifo, regSb, csrf);
  endrule

  rule doMemoryStage2ICache (m1m2Fifo.notEmpty &&
      m1m2Fifo.first.m2Op == M2OpICache);
    let done <- iCache.cacopResp();
    doMemoryStage2Body(tagged Invalid, tagged Valid done, tagged Invalid, m1m2Fifo, m2wFifo, regSb, csrf);
  endrule

  rule doMemoryStage2Tlb (m1m2Fifo.notEmpty &&
      m1m2Fifo.first.m2Op == M2OpTlb);
    let res <- tlb.resp();
    doMemoryStage2Body(tagged Invalid, tagged Invalid, tagged Valid res, m1m2Fifo, m2wFifo, regSb, csrf);
  endrule

  // ============================================================
  // Stage 7: WB — Writeback to RF/CSR, Exception retirement, Pipeline flush
  // ============================================================
`ifdef CONFIG_WB_DEBUG
  rule driveVsimDebugWb (m2wFifo.notEmpty);
    let memPkt = m2wFifo.first;

    debugWsValidWire <= True;
    debugWbPcWire <= memPkt.pc;
`ifdef CONFIG_WB_DEBUG_INST
    debugWbInstWire <= memPkt.inst;
`endif
    if (memPkt.mInst matches tagged Valid .mInst) begin
      debugWbRfWdataWire <= mInst.data;
      if (mInst.dst matches tagged Valid .dst) begin
        debugWbRfWnumWire <= dst;
        if (!memPkt.excp.valid && dst != 0) begin
          debugWbRfWenWire <= 4'hf;
        end
      end
    end
  endrule
`endif

`ifdef CONFIG_WB_DEBUG
  rule doWriteback (!debugBreakPoint);
`else
  rule doWriteback;
`endif
    doWritebackBody(m2wFifo, rf, csrf, pcReg[2], idleLock, iCache, dCache, tlb, regSb, csrSb, memRedirectPending, if2WaitRefill, f1f2Fifo, f2dFifo, d2rFifo, r2eFifo, e2mFifo, m1m2Fifo, mulInFlight, divInFlight
`ifdef CONFIG_DIFFTEST
    , difftest
`endif
`ifdef CONFIG_BSIM
    , toHostFifo
`endif
    );
  endrule

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

  method Data rfRdata = debugInforFlag ? rf.rdDebug(debugRegNum) : 0;

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
