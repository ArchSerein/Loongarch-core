import Types::*;
import ProcTypes::*;
import Ehr::*;
import ConfigReg::*;
import Fifo::*;
import Vector::*;
`include "CsrAddr.bsv"
`include "Autoconf.bsv"
`ifdef CONFIG_DIFFTEST
import DiffTypes::*;
`endif

interface CsrFile;
  method Data crmd;
  method Data prmd;
  method Data ecfg;
  method Data estat;
  method Data tcfg;
  method Data tval;
  method Data asid;
  method Data dmw0;
  method Data dmw1;
  method Data tlbidx;
  method Data rd(CsrIndx idx);
  method Bit#(64) stableCounterValue;
  method Action wr(Maybe#(CsrIndx) idx, Data val);
  method Data tlbehi;
  method Bit#(5) tlbReadIndex;
  method Data tlbWriteIdx;
  method Data tlbWriteEhi;
  method Data tlbWriteElo0;
  method Data tlbWriteElo1;
  method Data tlbWriteAsid;
  method Action applyTlbsrchResult(Data res);
  method Action applyTlbrdResult(Bool ne, Bit#(6) ps, Data ehi, Data elo0,
    Data elo1, Data asidVal);
  method Action commitTlbOp;
  method ActionValue#(Addr) raiseException(Bit#(6) ecode, Bit#(9) esubcode, Addr pc, Addr badv);
  method ActionValue#(Addr) returnFromException;
  `ifdef CONFIG_BSIM
    method ActionValue#(CpuToHostData) cpuToHost;
    method Bool cpuToHostValid;
  `endif
  `ifdef CONFIG_DIFFTEST
    method DiffArchCsrState diffSnapshot;
    method DiffArchCsrState diffSnapshotAfterWrite(Maybe#(CsrIndx) idx, Data val, Bool raiseExcp, Bit#(6) ecode, Bit#(9) esubcode, Addr pc, Addr badv, Bool isErtn);
    method DiffArchCsrState diffSnapshotAfterTlbrd(Bool ne, Bit#(6) ps, Data ehi, Data elo0, Data elo1, Data asidVal);
  `endif
endinterface

function Bool updateBadvOnException(Bit#(6) ecode);
  return (ecode == `ECODE_TLBR) || (ecode == `ECODE_ADE) || (ecode == `ECODE_ALE) ||
         (ecode == `ECODE_PIL) || (ecode == `ECODE_PIS) || (ecode == `ECODE_PIF) ||
         (ecode == `ECODE_PME) || (ecode == `ECODE_PPI);
endfunction

function Bool updateTlbehiOnException(Bit#(6) ecode);
  return (ecode == `ECODE_TLBR) || (ecode == `ECODE_PIL) || (ecode == `ECODE_PIS) ||
         (ecode == `ECODE_PIF) || (ecode == `ECODE_PME) || (ecode == `ECODE_PPI);
endfunction

function Data effectiveTlbIdxForWrite(Data tlbidx, Data estat);
  Data nextTlbidx = tlbidx;
  if (estat[`CSR_ESTAT_ECODE] == `ECODE_TLBR) begin
    nextTlbidx[`CSR_TLBIDX_NE] = 1'b0;
  end
  return nextTlbidx;
endfunction

function Data csrEstatWithTimerInt(Data estat, Bool timerIntPending);
  Data nextEstat = estat;
  nextEstat[`CSR_ESTAT_IS_2] = pack(timerIntPending);
  return nextEstat;
endfunction

function Data setTimerIntPending(Data estat);
  Data nextEstat = estat;
  nextEstat[`CSR_ESTAT_IS_2] = 1'b1;
  return nextEstat;
endfunction

function Data clearTimerIntPending(Data estat);
  Data nextEstat = estat;
  nextEstat[`CSR_ESTAT_IS_2] = 1'b0;
  return nextEstat;
endfunction

function Data updateTimerView(Data tcfg, Data tval, Bool timerInt, Bool wrote_tcfg, Bool cleared_timer_int);
  Data next_tval = tval;
  Bool next_timerInt = timerInt;

  if (!wrote_tcfg && !cleared_timer_int && tcfg[`CSR_TCFG_EN] == 1) begin
    if (next_tval != 0) begin
      let tval_next = next_tval - 1;
      if (tval_next == 0) begin
        next_timerInt = True;
        if (tcfg[`CSR_TCFG_PERIOD] == 1)
          next_tval = {tcfg[`CSR_TCFG_INITV], 2'b0};
        else
          next_tval = 0;
      end else begin
        next_tval = tval_next;
      end
    end
  end

  return (next_timerInt ? 32'h80000000 : 32'h0) | next_tval;
endfunction

`ifdef CONFIG_DIFFTEST
function DiffArchCsrState diffSnapshotAfterWriteFromState(
    DiffArchCsrState curr,
    Maybe#(CsrIndx) csrIdx,
    Data val,
    Bool raiseExcp,
    Bit#(6) ecode,
    Bit#(9) esubcode,
    Addr pc,
    Addr badv,
    Bool isErtn);
  Data next_crmd = curr.crmd;
  Data next_prmd = curr.prmd;
  Data next_euen = curr.euen;
  Data next_ecfg = curr.ecfg;
  Data next_era = curr.era;
  Data next_badv = curr.badv;
  Data next_eentry = curr.eentry;
  Data next_tlbidx = curr.tlbidx;
  Data next_tlbehi = curr.tlbehi;
  Data next_tlbelo0 = curr.tlbelo0;
  Data next_tlbelo1 = curr.tlbelo1;
  Data next_asid = curr.asid;
  Data next_pgdl = curr.pgdl;
  Data next_pgdh = curr.pgdh;
  Data next_save0 = curr.save0;
  Data next_save1 = curr.save1;
  Data next_save2 = curr.save2;
  Data next_save3 = curr.save3;
  Data next_tid = curr.tid;
  Data next_tcfg = curr.tcfg;
  Data next_tval = curr.tval;
  Bool next_llbit = unpack(curr.llbctl[0]);
  Bool next_llbctlKlo = unpack(curr.llbctl[2]);
  Data next_tlbrentry = curr.tlbrentry;
  Data next_dmw0 = curr.dmw0;
  Data next_dmw1 = curr.dmw1;
  Data next_estat_raw = curr.estat;
  Bool wrote_tcfg = False;
  Bool cleared_timer_int = False;

  if (raiseExcp) begin
    next_crmd[`CSR_CRMD_PLV] = 2'b0;
    next_crmd[`CSR_CRMD_IE] = 1'b0;
    if (ecode == `ECODE_TLBR) begin
      next_crmd[`CSR_CRMD_DA] = 1'b1;
      next_crmd[`CSR_CRMD_PG] = 1'b0;
    end
    next_prmd[`CSR_PRMD_PPLV] = curr.crmd[`CSR_CRMD_PLV];
    next_prmd[`CSR_PRMD_PIE] = curr.crmd[`CSR_CRMD_IE];
    next_estat_raw[`CSR_ESTAT_ECODE] = ecode;
    next_estat_raw[`CSR_ESTAT_ESUBCODE] = esubcode;
    next_era = pc;
    if (updateBadvOnException(ecode)) begin
      next_badv = badv;
    end
    if (updateTlbehiOnException(ecode)) begin
      next_tlbehi[`CSR_TLBEHI_VPPN] = badv[31:13];
    end
  end else if (isErtn) begin
    next_crmd[`CSR_CRMD_PLV] = curr.prmd[`CSR_PRMD_PPLV];
    next_crmd[`CSR_CRMD_IE] = curr.prmd[`CSR_PRMD_PIE];
    if (curr.estat[`CSR_ESTAT_ECODE] == `ECODE_TLBR) begin
      next_crmd[`CSR_CRMD_DA] = 1'b0;
      next_crmd[`CSR_CRMD_PG] = 1'b1;
    end
    if (!next_llbctlKlo) begin
      next_llbit = False;
    end
    next_llbctlKlo = False;
  end else if (csrIdx matches tagged Valid .idx) begin
    case (idx)
      `CSR_CRMD: next_crmd = (val & 32'h000001FF) | (next_crmd & 32'hFFFFFE00);
      `CSR_PRMD: next_prmd = (val & 32'h00000007) | (next_prmd & 32'hFFFFFFF8);
      `CSR_EUEN: next_euen = (val & 32'h00000001) | (next_euen & 32'hFFFFFFFE);
      `CSR_ECFG: next_ecfg = (val & 32'h00001BFF) | (next_ecfg & 32'hFFFFE400);
      `CSR_ESTAT: next_estat_raw = (val & 32'h00000003) | (next_estat_raw & 32'hFFFFFFFC);
      `CSR_ERA: next_era = val;
      `CSR_BADV: next_badv = val;
      `CSR_EENTRY: next_eentry = (val & 32'hFFFFFFC0) | (next_eentry & 32'h0000003F);
      `CSR_TLBIDX: next_tlbidx = (val & 32'hBF00001F) | (next_tlbidx & 32'h40FFFFE0);
      `CSR_TLBEHI: next_tlbehi = (val & 32'hFFFFE000) | (next_tlbehi & 32'h00001FFF);
      `CSR_TLBEL0: next_tlbelo0 = (val & 32'h0FFFFF7F) | (next_tlbelo0 & 32'hF0000080);
      `CSR_TLBEL1: next_tlbelo1 = (val & 32'h0FFFFF7F) | (next_tlbelo1 & 32'hF0000080);
      `CSR_ASID: next_asid = (val & 32'h000003FF) | (next_asid & 32'hFFFFFC00);
      `CSR_PGDL: next_pgdl = (val & 32'hFFFFF000) | (next_pgdl & 32'h00000FFF);
      `CSR_PGDH: next_pgdh = (val & 32'hFFFFF000) | (next_pgdh & 32'h00000FFF);
      `CSR_SAVE0: next_save0 = val;
      `CSR_SAVE1: next_save1 = val;
      `CSR_SAVE2: next_save2 = val;
      `CSR_SAVE3: next_save3 = val;
      `CSR_TID: next_tid = val;
      `CSR_TCFG: begin
        next_tcfg = val;
        next_tval = {val[`CSR_TCFG_INITV], 2'b0};
        wrote_tcfg = True;
        if (val[`CSR_TCFG_EN] == 1'b1 && val[`CSR_TCFG_INITV] == 0) begin
          next_estat_raw = setTimerIntPending(next_estat_raw);
        end
      end
      `CSR_TICLR: begin
        if (val[`CSR_TICLR_CLR] == 1'b1) begin
          next_estat_raw = clearTimerIntPending(next_estat_raw);
          cleared_timer_int = True;
        end
      end
      `CSR_LLBCTL: begin
        if (val[1] == 1) next_llbit = False;
        next_llbctlKlo = unpack(val[2]);
      end
      `CSR_TLBRENTRY: next_tlbrentry = (val & 32'hFFFFFFC0) | (next_tlbrentry & 32'h0000003F);
      `CSR_DMW0: next_dmw0 = (val & 32'hEE000039) | (next_dmw0 & 32'h11FFFFC6);
      `CSR_DMW1: next_dmw1 = (val & 32'hEE000039) | (next_dmw1 & 32'h11FFFFC6);
      default: begin end
    endcase
  end

  if (!raiseExcp && !wrote_tcfg && !cleared_timer_int && next_tcfg[`CSR_TCFG_EN] == 1) begin
    if (next_tval != 0) begin
      let tval_next = next_tval - 1;
      if (tval_next == 0) begin
        next_estat_raw = setTimerIntPending(next_estat_raw);
        if (next_tcfg[`CSR_TCFG_PERIOD] == 1)
          next_tval = {next_tcfg[`CSR_TCFG_INITV], 2'b0};
        else
          next_tval = 0;
      end else begin
        next_tval = tval_next;
      end
    end
  end

  return DiffArchCsrState{
    crmd: next_crmd,
    prmd: next_prmd,
    euen: next_euen,
    ecfg: next_ecfg,
    era: next_era,
    badv: next_badv,
    eentry: next_eentry,
    tlbidx: next_tlbidx,
    tlbehi: next_tlbehi,
    tlbelo0: next_tlbelo0,
    tlbelo1: next_tlbelo1,
    asid: next_asid,
    pgdl: next_pgdl,
    pgdh: next_pgdh,
    save0: next_save0,
    save1: next_save1,
    save2: next_save2,
    save3: next_save3,
    tid: next_tid,
    tcfg: next_tcfg,
    tval: next_tval,
    llbctl: {29'b0, pack(next_llbctlKlo), 1'b0, pack(next_llbit)},
    tlbrentry: next_tlbrentry,
    dmw0: next_dmw0,
    dmw1: next_dmw1,
    estat: next_estat_raw
  };
endfunction

function DiffArchCsrState diffSnapshotFromFields(
    Data crmd,
    Data prmd,
    Data euen,
    Data ecfg,
    Data era,
    Data badv,
    Data eentry,
    Data tlbidx,
    Data tlbehi,
    Data tlbelo0,
    Data tlbelo1,
    Data asid,
    Data pgdl,
    Data pgdh,
    Data save0,
    Data save1,
    Data save2,
    Data save3,
    Data tid,
    Data tcfg,
    Data tval,
    Bool llbctlKlo,
    Bool llbit,
    Data tlbrentry,
    Data dmw0,
    Data dmw1,
    Data estat);
  return DiffArchCsrState{
    crmd: crmd,
    prmd: prmd,
    euen: euen,
    ecfg: ecfg,
    era: era,
    badv: badv,
    eentry: eentry,
    tlbidx: tlbidx,
    tlbehi: tlbehi,
    tlbelo0: tlbelo0,
    tlbelo1: tlbelo1,
    asid: asid,
    pgdl: pgdl,
    pgdh: pgdh,
    save0: save0,
    save1: save1,
    save2: save2,
    save3: save3,
    tid: tid,
    tcfg: tcfg,
    tval: tval,
    llbctl: {29'b0, pack(llbctlKlo), 1'b0, pack(llbit)},
    tlbrentry: tlbrentry,
    dmw0: dmw0,
    dmw1: dmw1,
    estat: estat
  };
endfunction

function DiffArchCsrState diffSnapshotAfterTlbrdFromState(
    DiffArchCsrState curr,
    Bool ne,
    Bit#(6) ps,
    Data ehi,
    Data elo0,
    Data elo1,
    Data asidVal);
  Data next_tlbidx = zeroExtend(curr.tlbidx[`CSR_TLBIDX_INDEX]);
  Data next_tlbehi = 0;
  Data next_tlbelo0 = 0;
  Data next_tlbelo1 = 0;
  Data next_asid = curr.asid;
  Data next_tval = curr.tval;
  Data next_tcfg = curr.tcfg;
  Data next_estat = curr.estat;

  if (ne) begin
    next_tlbidx[31] = 1'b1;
    next_asid = next_asid & 32'hFFFFFC00;
  end else begin
    next_tlbidx[29:24] = ps;
    next_tlbehi = ehi;
    next_tlbelo0 = elo0;
    next_tlbelo1 = elo1;
    next_asid = (next_asid & 32'hFFFFFC00) | (asidVal & 32'h000003FF);
  end

  if (next_tcfg[`CSR_TCFG_EN] == 1) begin
    if (next_tval != 0) begin
      let tval_next = next_tval - 1;
      if (tval_next == 0) begin
        next_estat = setTimerIntPending(next_estat);
        if (next_tcfg[`CSR_TCFG_PERIOD] == 1)
          next_tval = {next_tcfg[`CSR_TCFG_INITV], 2'b0};
        else
          next_tval = 0;
      end else begin
        next_tval = tval_next;
      end
    end
  end

  return DiffArchCsrState{
    crmd: curr.crmd,
    prmd: curr.prmd,
    euen: curr.euen,
    ecfg: curr.ecfg,
    era: curr.era,
    badv: curr.badv,
    eentry: curr.eentry,
    tlbidx: next_tlbidx,
    tlbehi: next_tlbehi,
    tlbelo0: next_tlbelo0,
    tlbelo1: next_tlbelo1,
    asid: next_asid,
    pgdl: curr.pgdl,
    pgdh: curr.pgdh,
    save0: curr.save0,
    save1: curr.save1,
    save2: curr.save2,
    save3: curr.save3,
    tid: curr.tid,
    tcfg: next_tcfg,
    tval: next_tval,
    llbctl: curr.llbctl,
    tlbrentry: curr.tlbrentry,
    dmw0: curr.dmw0,
    dmw1: curr.dmw1,
    estat: next_estat
  };
endfunction
`endif

(* synthesize *)
module mkCsrFile(CsrFile);
  Reg#(Bit#(64)) commitInsts <- mkReg(0);
  Reg#(Bit#(64)) cycles <- mkReg(0);

  `ifdef CONFIG_BSIM
  Fifo#(2, CpuToHostData) toHostFifo <- mkCFFifo;
  `endif

  Reg#(Data) csr_crmd <- mkReg(32'h00000008); // DA=1 on reset
  Reg#(Data) csr_prmd <- mkReg(0);
  Reg#(Data) csr_euen <- mkReg(0);

  Reg#(Data) csr_ecfg <- mkReg(0);
  Reg#(Data) csr_estat <- mkReg(0); // IS10 RW, Ecode/EsubCode HW-set
  Reg#(Data) csr_era <- mkReg(0);
  Reg#(Data) csr_badv <- mkReg(0);
  Reg#(Data) csr_eentry <- mkReg(0);

  Reg#(Data) csr_tlbidx <- mkReg(0);
  Reg#(Data) csr_tlbehi <- mkReg(0);
  Reg#(Data) csr_tlbelo0 <- mkReg(0);
  Reg#(Data) csr_tlbelo1 <- mkReg(0);
  Reg#(Data) csr_asid <- mkReg(32'h000A0000); // ASIDBITS=10
  Reg#(Data) csr_pgdl <- mkReg(0);
  Reg#(Data) csr_pgdh <- mkReg(0);
  Reg#(Data) csr_tlbrentry <- mkReg(0);

  Reg#(Data) csr_save0 <- mkRegU;
  Reg#(Data) csr_save1 <- mkRegU;
  Reg#(Data) csr_save2 <- mkRegU;
  Reg#(Data) csr_save3 <- mkRegU;

  Reg#(Data)    csr_tid <- mkReg(0);
  Reg#(Data)    csr_tcfg <- mkReg(0);
  Reg#(Data)    csr_tval <- mkRegU;
  Reg#(Bool)    timerIntPending <- mkReg(False);
  Reg#(Bool)    tcfgWriteEpoch <- mkReg(False);
  Reg#(Bool)    tcfgWriteSeen <- mkReg(False);
  Reg#(Bool)    timerIntClearEpoch <- mkReg(False);
  Reg#(Bool)    timerIntClearSeen <- mkReg(False);

  Reg#(Bool) llbit <- mkReg(False);
  Reg#(Bool) llbctlKlo <- mkReg(False);

  Reg#(Data) csr_ctag <- mkReg(0);
  Reg#(Data) csr_dmw0 <- mkReg(0);
  Reg#(Data) csr_dmw1 <- mkReg(0);

  rule count;
    cycles <= cycles + 1;
    Data next_tval = csr_tval;
    Bool tcfgWritePending = tcfgWriteEpoch != tcfgWriteSeen;
    Bool timerIntClearPending = timerIntClearEpoch != timerIntClearSeen;
    Bool nextTimerIntPending = timerIntClearPending ? False : timerIntPending;

    if (tcfgWritePending) begin
      next_tval = { csr_tcfg[`CSR_TCFG_INITV], 2'b0 };
      if (csr_tcfg[`CSR_TCFG_EN] == 1'b1 && csr_tcfg[`CSR_TCFG_INITV] == 0) begin
        nextTimerIntPending = True;
      end
      tcfgWriteSeen <= tcfgWriteEpoch;
    end else if (csr_tcfg[`CSR_TCFG_EN] == 1) begin
      if (csr_tval == 0) begin
        next_tval = csr_tcfg[`CSR_TCFG_PERIOD] == 1'b1 ? { csr_tcfg[`CSR_TCFG_INITV], 2'b0 } : 0;
      end else begin
        let tval_next = csr_tval - 1;
        next_tval = tval_next;
        if (tval_next == 0) begin
          nextTimerIntPending = True;
          next_tval = csr_tcfg[`CSR_TCFG_PERIOD] == 1'b1 ? { csr_tcfg[`CSR_TCFG_INITV], 2'b0 } : 0;
        end
      end
    end
    if (timerIntClearPending) begin
      timerIntClearSeen <= timerIntClearEpoch;
    end
    csr_tval <= next_tval;
    timerIntPending <= nextTimerIntPending;
  endrule

  method Data crmd;
    return csr_crmd;
  endmethod

  method Data prmd;
    return csr_prmd;
  endmethod

  method Data ecfg;
    return csr_ecfg;
  endmethod

  method Data estat;
    return csrEstatWithTimerInt(csr_estat, timerIntPending);
  endmethod

  method Data tcfg;
    return csr_tcfg;
  endmethod

  method Data tval;
    return csr_tval;
  endmethod

  method Data dmw0;
    return csr_dmw0;
  endmethod

  method Data dmw1;
    return csr_dmw1;
  endmethod

  method Data asid;
    return csr_asid;
  endmethod

  method Data rd(CsrIndx idx);
    Data res = 0;
    case (idx)
        `CSR_CRMD: res = csr_crmd; 
        `CSR_PRMD: res = csr_prmd;
        `CSR_EUEN: res = csr_euen; 
        `CSR_ECFG: res = csr_ecfg;
        `CSR_ESTAT: res = csrEstatWithTimerInt(csr_estat, timerIntPending);
        `CSR_ERA: res = csr_era;
        `CSR_BADV: res = csr_badv; 
        `CSR_EENTRY: res = csr_eentry;
        `CSR_TLBIDX: res = csr_tlbidx; 
        `CSR_TLBEHI: res = csr_tlbehi;
        `CSR_TLBEL0: res = csr_tlbelo0; 
        `CSR_TLBEL1: res = csr_tlbelo1;
        `CSR_ASID: res = csr_asid; 
        `CSR_PGDL: res = csr_pgdl;
        `CSR_PGDH: res = csr_pgdh; 
        `CSR_PGD: res = (csr_badv[31] == 1) ? csr_pgdh : csr_pgdl;
        `CSR_CPUID: res = 0; 
        `CSR_SAVE0: res = csr_save0;
        `CSR_SAVE1: res = csr_save1; 
        `CSR_SAVE2: res = csr_save2;
        `CSR_SAVE3: res = csr_save3; 
        `CSR_TID: res = csr_tid;
        `CSR_TCFG: res = csr_tcfg; 
        `CSR_TVAL: res = csr_tval;
        `CSR_TICLR: res = 0; 
        `CSR_LLBCTL: res = {29'b0, pack(llbctlKlo), 1'b0, pack(llbit)};
        `CSR_TLBRENTRY: res = csr_tlbrentry; 
        `CSR_CTAG: res = csr_ctag;
        `CSR_DMW0: res = csr_dmw0; 
        `CSR_DMW1: res = csr_dmw1;
        default: res = 0;
    endcase
    return res;
  endmethod

  method Bit#(64) stableCounterValue;
    return cycles;
  endmethod

`ifdef CONFIG_DIFFTEST
  method DiffArchCsrState diffSnapshot;
    let estatWithTimer = csrEstatWithTimerInt(csr_estat, timerIntPending);
    return diffSnapshotFromFields(csr_crmd, csr_prmd, csr_euen, csr_ecfg, csr_era, csr_badv,
      csr_eentry, csr_tlbidx, csr_tlbehi, csr_tlbelo0, csr_tlbelo1, csr_asid, csr_pgdl,
      csr_pgdh, csr_save0, csr_save1, csr_save2, csr_save3, csr_tid, csr_tcfg, csr_tval,
      llbctlKlo, llbit, csr_tlbrentry, csr_dmw0, csr_dmw1, estatWithTimer);
  endmethod

  method DiffArchCsrState diffSnapshotAfterWrite(Maybe#(CsrIndx) csrIdx, Data val, Bool raiseExcp,
      Bit#(6) ecode, Bit#(9) esubcode, Addr pc, Addr badv, Bool isErtn);
    let estatWithTimer = csrEstatWithTimerInt(csr_estat, timerIntPending);
    let curr = diffSnapshotFromFields(csr_crmd, csr_prmd, csr_euen, csr_ecfg, csr_era, csr_badv,
      csr_eentry, csr_tlbidx, csr_tlbehi, csr_tlbelo0, csr_tlbelo1, csr_asid, csr_pgdl,
      csr_pgdh, csr_save0, csr_save1, csr_save2, csr_save3, csr_tid, csr_tcfg, csr_tval,
      llbctlKlo, llbit, csr_tlbrentry, csr_dmw0, csr_dmw1, estatWithTimer);
    return diffSnapshotAfterWriteFromState(curr, csrIdx, val, raiseExcp, ecode, esubcode, pc,
      badv, isErtn);
  endmethod

  method DiffArchCsrState diffSnapshotAfterTlbrd(Bool ne, Bit#(6) ps, Data ehi, Data elo0, Data elo1, Data asidVal);
    let estatWithTimer = csrEstatWithTimerInt(csr_estat, timerIntPending);
    let curr = diffSnapshotFromFields(csr_crmd, csr_prmd, csr_euen, csr_ecfg, csr_era, csr_badv,
      csr_eentry, csr_tlbidx, csr_tlbehi, csr_tlbelo0, csr_tlbelo1, csr_asid, csr_pgdl,
      csr_pgdh, csr_save0, csr_save1, csr_save2, csr_save3, csr_tid, csr_tcfg, csr_tval,
      llbctlKlo, llbit, csr_tlbrentry, csr_dmw0, csr_dmw1, estatWithTimer);
    return diffSnapshotAfterTlbrdFromState(curr, ne, ps, ehi, elo0, elo1, asidVal);
  endmethod
`endif

  method Action wr(Maybe#(CsrIndx) csrIdx, Data val);
    if (csrIdx matches tagged Valid .idx) begin
      case (idx)
        `CSR_CRMD: csr_crmd <= (val & 32'h000001FF) | (csr_crmd   &
          32'hFFFFFE00);

        `CSR_PRMD: csr_prmd <= (val & 32'h00000007) | (csr_prmd   &
          32'hFFFFFFF8);

        `CSR_EUEN: csr_euen <= (val & 32'h00000001) | (csr_euen   &
          32'hFFFFFFFE);

        `CSR_ECFG: csr_ecfg <= (val & 32'h00001BFF) | (csr_ecfg   &
          32'hFFFFE400);

        `CSR_ESTAT: csr_estat <= (val & 32'h00000003) | (csr_estat  &
          32'hFFFFFFFC);

        `CSR_ERA: csr_era <= val;

        `CSR_BADV: csr_badv <= val;

        `CSR_EENTRY: csr_eentry <= (val & 32'hFFFFFFC0) | (csr_eentry &
          32'h0000003F);

        `CSR_TLBIDX: csr_tlbidx <= (val & 32'hBF00001F) | (csr_tlbidx &
          32'h40FFFFE0);

        `CSR_TLBEHI: csr_tlbehi <= (val & 32'hFFFFE000) | (csr_tlbehi &
          32'h00001FFF);

        `CSR_TLBEL0: csr_tlbelo0 <= (val & 32'h0FFFFF7F) | (csr_tlbelo0 &
          32'hF0000080);
        `CSR_TLBEL1: csr_tlbelo1 <= (val & 32'h0FFFFF7F) | (csr_tlbelo1 &
          32'hF0000080);

        `CSR_ASID: csr_asid <= (val & 32'h000003FF) | (csr_asid   &
          32'hFFFFFC00);

        `CSR_PGDL: csr_pgdl <= (val & 32'hFFFFF000) | (csr_pgdl   &
          32'h00000FFF);
        `CSR_PGDH: csr_pgdh <= (val & 32'hFFFFF000) | (csr_pgdh   &
          32'h00000FFF);

        `CSR_SAVE0: csr_save0 <= val;
        `CSR_SAVE1: csr_save1 <= val;
        `CSR_SAVE2: csr_save2 <= val;
        `CSR_SAVE3: csr_save3 <= val;

        `CSR_TID: csr_tid <= val;

        `CSR_TCFG: begin
          csr_tcfg <= val;
          tcfgWriteEpoch <= !tcfgWriteEpoch;
        end

        `CSR_TICLR: begin
          if (val[`CSR_TICLR_CLR] == 1'b1) begin
            timerIntClearEpoch <= !timerIntClearEpoch;
          end
        end

        `CSR_LLBCTL: begin
          if (val[1] == 1) llbit <= False;
          llbctlKlo <= unpack(val[2]);
        end

        `CSR_TLBRENTRY: csr_tlbrentry <= (val & 32'hFFFFFFC0) | (csr_tlbrentry
          & 32'h0000003F);

        `CSR_CTAG: csr_ctag <= val;

        `CSR_DMW0: csr_dmw0 <= (val & 32'hEE000039) | (csr_dmw0 &
          32'h11FFFFC6);
        `CSR_DMW1: csr_dmw1 <= (val & 32'hEE000039) | (csr_dmw1 &
          32'h11FFFFC6);
        endcase
      end
    endmethod

    method Data tlbehi;
      return csr_tlbehi;
    endmethod

    method Bit#(5) tlbReadIndex;
      return csr_tlbidx[`CSR_TLBIDX_INDEX];
    endmethod

    method Data tlbWriteIdx;
      return effectiveTlbIdxForWrite(csr_tlbidx, csr_estat);
    endmethod

    method Data tlbWriteEhi;
      return csr_tlbehi;
    endmethod

    method Data tlbWriteElo0;
      return csr_tlbelo0;
    endmethod

    method Data tlbWriteElo1;
      return csr_tlbelo1;
    endmethod

    method Data tlbWriteAsid;
      return csr_asid;
    endmethod

    method Data tlbidx;
      return csr_tlbidx;
    endmethod

    method Action applyTlbsrchResult(Data res);
      csr_tlbidx <= (res & 32'hBF00001F) | (csr_tlbidx & 32'h40FFFFE0);
    endmethod

    method Action applyTlbrdResult(Bool ne, Bit#(6) ps, Data ehi, Data elo0,
        Data elo1, Data asidVal);
      Data next_tlbidx = zeroExtend(csr_tlbidx[`CSR_TLBIDX_INDEX]);
      if (ne) begin
        next_tlbidx[31] = 1'b1;
        csr_tlbehi <= 0;
        csr_tlbelo0 <= 0;
        csr_tlbelo1 <= 0;
        csr_asid <= csr_asid & 32'hFFFFFC00;
      end else begin
        next_tlbidx[29:24] = ps;
        csr_tlbehi <= ehi;
        csr_tlbelo0 <= elo0;
        csr_tlbelo1 <= elo1;
        csr_asid <= (csr_asid & 32'hFFFFFC00) | (asidVal & 32'h000003FF);
      end
      csr_tlbidx <= next_tlbidx;
    endmethod

    method Action commitTlbOp;
      noAction;
    endmethod

    method ActionValue#(Addr) raiseException(Bit#(6) ecode, Bit#(9) esubcode, Addr pc, Addr badv);
      Data nextCrmd   = csr_crmd;
      Bit#(2) currPlv = csr_crmd[`CSR_CRMD_PLV];
      Bit#(1) currIe  = csr_crmd[`CSR_CRMD_IE];
      nextCrmd[`CSR_CRMD_PLV] = 2'b0;
      nextCrmd[`CSR_CRMD_IE] = 1'b0;
      // TLB 重填异常切换到直接地址翻译模式
      if (ecode == `ECODE_TLBR) begin
        nextCrmd[`CSR_CRMD_DA] = 1'b1;
        nextCrmd[`CSR_CRMD_PG] = 1'b0;
      end

      Data nextPrmd = csr_prmd;
      nextPrmd[`CSR_PRMD_PPLV] = currPlv;
      nextPrmd[`CSR_PRMD_PIE] = currIe;

      Data nextEstat = csr_estat;
      nextEstat[`CSR_ESTAT_ECODE] = ecode;
      nextEstat[`CSR_ESTAT_ESUBCODE] = esubcode;

      csr_crmd <= nextCrmd;
      csr_prmd <= nextPrmd;
      csr_estat <= nextEstat;
      csr_era <= pc;
      if (updateBadvOnException(ecode)) begin
        csr_badv <= badv;
      end
      if (updateTlbehiOnException(ecode)) begin
        csr_tlbehi[`CSR_TLBEHI_VPPN] <= badv[31:13];
      end
      return (ecode == `ECODE_TLBR) ? csr_tlbrentry : csr_eentry;
    endmethod

    method ActionValue#(Addr) returnFromException;
      Data nextCrmd = csr_crmd;
      nextCrmd[`CSR_CRMD_PLV] = csr_prmd[`CSR_PRMD_PPLV];
      nextCrmd[`CSR_CRMD_IE] = csr_prmd[`CSR_PRMD_PIE];
      if (csr_estat[`CSR_ESTAT_ECODE] == `ECODE_TLBR) begin
        nextCrmd[`CSR_CRMD_DA] = 1'b0;
        nextCrmd[`CSR_CRMD_PG] = 1'b1;
      end
      if (!llbctlKlo) begin
        llbit <= False;
      end
      llbctlKlo <= False;
      csr_crmd <= nextCrmd;
      return csr_era;
    endmethod

    `ifdef CONFIG_BSIM
    method ActionValue#(CpuToHostData) cpuToHost if (toHostFifo.notEmpty);
      let ret = toHostFifo.first;
      toHostFifo.deq;
      return ret;
    endmethod

    method Bool cpuToHostValid = toHostFifo.notEmpty;
    `endif
  endmodule
