import Types::*;
import ProcTypes::*;
import Ehr::*;
import ConfigReg::*;
import Fifo::*;
import Vector::*;
`include "CsrAddr.bsv"
`include "Autoconf.bsv"

interface CsrFile;
  method Action start;
  method Action finish;
  method Bool started;
  method Bool hasInterrupt;
  method Data crmd;
  method Data prmd;
  method Data ecfg;
  method Data estat;
  method Data tcfg;
  method Data tval;
  method Data rd(CsrIndx idx);
  method Bit#(64) stableCounterValue;
`ifdef CONFIG_DIFFTEST
    method DiffArchCsrState diffSnapshot;
    method DiffArchCsrState diffSnapshotAfterWrite(Maybe#(CsrIndx) idx, Data val, Bool raiseExcp, Bit#(6) ecode, Bit#(9) esubcode, Addr pc, Addr badv);
    method DiffArchCsrState diffSnapshotAfterTlbrd;
`endif
  method Action wr(Maybe#(CsrIndx) idx, Data val);
  method Action tlbwr;
  method Action tlbrd;
  method ActionValue#(Addr) raiseException(Bit#(6) ecode, Bit#(9) esubcode, Addr pc, Addr badv);
  method ActionValue#(Addr) returnFromException;
  method ActionValue#(CpuToHostData) cpuToHost;
  method Bool cpuToHostValid;
endinterface

function Bool updateBadvOnException(Bit#(6) ecode);
  return (ecode == `ECODE_ADE) || (ecode == `ECODE_ALE);
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

(* synthesize *)
module mkCsrFile(CsrFile);
  Reg#(Bool) startReg <- mkReg(False);

  Reg#(Bit#(64)) commitInsts <- mkReg(0);
  Reg#(Bit#(64)) cycles <- mkReg(0);

  Fifo#(2, CpuToHostData) toHostFifo <- mkCFFifo;

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
  Ehr#(2, Data) csr_tval <- mkEhr(0); // port 0: timer rule, port 1: wr
  Ehr#(2, Bool) timerInt <- mkEhr(False); // port 0: timer rule, port 1: TICLR

  Reg#(Bool) llbit <- mkReg(False);
  Reg#(Bool) llbctlKlo <- mkReg(False);

  Reg#(Data) csr_ctag <- mkReg(0);
  Reg#(Data) csr_dmw0 <- mkReg(0);
  Reg#(Data) csr_dmw1 <- mkReg(0);

  Vector#(8, Reg#(Bool)) tlb_ne <- replicateM(mkReg(True));
  Vector#(8, Reg#(Bit#(6))) tlb_ps <- replicateM(mkReg(0));
  Vector#(8, Reg#(Data)) tlb_ehi <- replicateM(mkReg(0));
  Vector#(8, Reg#(Data)) tlb_elo0 <- replicateM(mkReg(0));
  Vector#(8, Reg#(Data)) tlb_elo1 <- replicateM(mkReg(0));
  Vector#(8, Reg#(Data)) tlb_asid <- replicateM(mkReg(0));

  rule count (startReg);
    cycles <= cycles + 1;
  endrule

  function Action retireBookkeeping(Bool wrote_tcfg, Bool cleared_timer_int);
    action
      if (!wrote_tcfg && !cleared_timer_int && startReg && csr_tcfg[`CSR_TCFG_EN] == 1) begin
        if (csr_tval[1] != 0) begin
          let tval_next = csr_tval[1] - 1;
          if (tval_next == 0) begin
            timerInt[1] <= True;
            if (csr_tcfg[`CSR_TCFG_PERIOD] == 1)
              csr_tval[1] <= {csr_tcfg[`CSR_TCFG_INITV], 2'b0};
            else
              csr_tval[1] <= 0;
          end else begin
            csr_tval[1] <= tval_next;
          end
        end
      end
      commitInsts <= commitInsts + 1;
    endaction
  endfunction

  method Action start if (!startReg);
    startReg <= True;
    cycles <= 0;
    commitInsts <= 0;
  endmethod

  method Action finish;
    $display("[CSR] commit instructions: %0d", commitInsts);
    toHostFifo.enq(CpuToHostData{
      c2hType: ExitCode,
      data: 16'b0});
  endmethod

  method Bool started;
    return startReg;
  endmethod

  method Bool hasInterrupt;
    Data estatWithTimer = csr_estat | (timerInt[1] ? 32'h00000800 : 0);
    Bool ieEnabled = (csr_crmd[`CSR_CRMD_IE] == 1'b1);
    Bool pending = ((estatWithTimer[`CSR_ECFG_LIE] & csr_ecfg[`CSR_ECFG_LIE]) != 0);
    return startReg && ieEnabled && pending;
  endmethod

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
    return csr_estat | (timerInt[1] ? 32'h00000800 : 0);
  endmethod

  method Data tcfg;
    return csr_tcfg;
  endmethod

  method Data tval;
    return csr_tval[1];
  endmethod

  method Data rd(CsrIndx idx);
    Data res = 0;
    case (idx)
        `CSR_CRMD: res = csr_crmd; 
        `CSR_PRMD: res = csr_prmd;
        `CSR_EUEN: res = csr_euen; 
        `CSR_ECFG: res = csr_ecfg;
        `CSR_ESTAT: res = csr_estat | (timerInt[1] ? 32'h00000800 : 0); 
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
        `CSR_TVAL: res = csr_tval[1];
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
    return DiffArchCsrState{
      crmd: csr_crmd,
      prmd: csr_prmd,
      euen: csr_euen,
      ecfg: csr_ecfg,
      era: csr_era,
      badv: csr_badv,
      eentry: csr_eentry,
      tlbidx: csr_tlbidx,
      tlbehi: csr_tlbehi,
      tlbelo0: csr_tlbelo0,
      tlbelo1: csr_tlbelo1,
      asid: csr_asid,
      pgdl: csr_pgdl,
      pgdh: csr_pgdh,
      save0: csr_save0,
      save1: csr_save1,
      save2: csr_save2,
      save3: csr_save3,
      tid: csr_tid,
      tcfg: csr_tcfg,
      tval: csr_tval[1],
      llbctl: {29'b0, pack(llbctlKlo), 1'b0, pack(llbit)},
      tlbrentry: csr_tlbrentry,
      dmw0: csr_dmw0,
      dmw1: csr_dmw1,
      estat: csr_estat | (timerInt[1] ? 32'h00000800 : 0)
    };
  endmethod

  method DiffArchCsrState diffSnapshotAfterWrite(Maybe#(CsrIndx) csrIdx, Data val, Bool raiseExcp,
      Bit#(6) ecode, Bit#(9) esubcode, Addr pc, Addr badv);
    Data next_crmd = csr_crmd;
    Data next_prmd = csr_prmd;
    Data next_euen = csr_euen;
    Data next_ecfg = csr_ecfg;
    Data next_era = csr_era;
    Data next_badv = csr_badv;
    Data next_eentry = csr_eentry;
    Data next_tlbidx = csr_tlbidx;
    Data next_tlbehi = csr_tlbehi;
    Data next_tlbelo0 = csr_tlbelo0;
    Data next_tlbelo1 = csr_tlbelo1;
    Data next_asid = csr_asid;
    Data next_pgdl = csr_pgdl;
    Data next_pgdh = csr_pgdh;
    Data next_save0 = csr_save0;
    Data next_save1 = csr_save1;
    Data next_save2 = csr_save2;
    Data next_save3 = csr_save3;
    Data next_tid = csr_tid;
    Data next_tcfg = csr_tcfg;
    Data next_tval = csr_tval[1];
    Bool next_timerInt = timerInt[1];
    Bool next_llbit = llbit;
    Bool next_llbctlKlo = llbctlKlo;
    Data next_tlbrentry = csr_tlbrentry;
    Data next_dmw0 = csr_dmw0;
    Data next_dmw1 = csr_dmw1;
    Data next_estat_raw = csr_estat;
    Bool wrote_tcfg = False;
    Bool cleared_timer_int = False;

    if (raiseExcp) begin
      next_crmd[`CSR_CRMD_PLV] = 2'b0;
      next_crmd[`CSR_CRMD_IE] = 1'b0;
      next_prmd[`CSR_PRMD_PPLV] = csr_crmd[`CSR_CRMD_PLV];
      next_prmd[`CSR_PRMD_PIE] = csr_crmd[`CSR_CRMD_IE];
      next_estat_raw[`CSR_ESTAT_ECODE] = ecode;
      next_estat_raw[`CSR_ESTAT_ESUBCODE] = esubcode;
      next_era = pc;
      if (updateBadvOnException(ecode)) begin
        next_badv = badv;
      end
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
        `CSR_TLBIDX: next_tlbidx = (val & 32'hBF00000F) | (next_tlbidx & 32'h40FFFFF0);
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
          if (val[`CSR_TCFG_EN] == 1 && val[`CSR_TCFG_INITV] == 0) begin
            next_timerInt = True;
          end
        end
        `CSR_TICLR: begin
          if (val[`CSR_TICLR_CLR] == 1) begin
            next_timerInt = False;
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
          next_timerInt = True;
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
      estat: next_estat_raw | (next_timerInt ? 32'h00000800 : 0)
    };
  endmethod

  method DiffArchCsrState diffSnapshotAfterTlbrd;
    Bit#(3) tlbIndex = truncate(csr_tlbidx[`CSR_TLBIDX_INDEX]);
    Data next_crmd = csr_crmd;
    Data next_prmd = csr_prmd;
    Data next_euen = csr_euen;
    Data next_ecfg = csr_ecfg;
    Data next_era = csr_era;
    Data next_badv = csr_badv;
    Data next_eentry = csr_eentry;
    Data next_tlbidx = zeroExtend(tlbIndex);
    Data next_tlbehi = 0;
    Data next_tlbelo0 = 0;
    Data next_tlbelo1 = 0;
    Data next_asid = csr_asid;
    Data next_pgdl = csr_pgdl;
    Data next_pgdh = csr_pgdh;
    Data next_save0 = csr_save0;
    Data next_save1 = csr_save1;
    Data next_save2 = csr_save2;
    Data next_save3 = csr_save3;
    Data next_tid = csr_tid;
    Data next_tcfg = csr_tcfg;
    Data next_tval = csr_tval[1];
    Bool next_timerInt = timerInt[1];
    Data next_tlbrentry = csr_tlbrentry;
    Data next_dmw0 = csr_dmw0;
    Data next_dmw1 = csr_dmw1;
    Data next_estat_raw = csr_estat;

    if (tlb_ne[tlbIndex]) begin
      next_tlbidx[31] = 1'b1;
    end else begin
      next_tlbidx[29:24] = tlb_ps[tlbIndex];
      next_tlbehi = tlb_ehi[tlbIndex];
      next_tlbelo0 = tlb_elo0[tlbIndex];
      next_tlbelo1 = tlb_elo1[tlbIndex];
      next_asid = (next_asid & 32'hFFFFFC00) | (tlb_asid[tlbIndex] & 32'h000003FF);
    end

    if (next_tcfg[`CSR_TCFG_EN] == 1) begin
      if (next_tval != 0) begin
        let tval_next = next_tval - 1;
        if (tval_next == 0) begin
          next_timerInt = True;
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
      llbctl: {29'b0, pack(llbctlKlo), 1'b0, pack(llbit)},
      tlbrentry: next_tlbrentry,
      dmw0: next_dmw0,
      dmw1: next_dmw1,
      estat: next_estat_raw | (next_timerInt ? 32'h00000800 : 0)
    };
  endmethod
  `endif

  method Action wr(Maybe#(CsrIndx) csrIdx, Data val);
    Bool wrote_tcfg = False;
    Bool cleared_timer_int = False;
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

        `CSR_TLBIDX: csr_tlbidx <= (val & 32'hBF00000F) | (csr_tlbidx &
          32'h40FFFFF0);

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
          csr_tval[1] <= {val[`CSR_TCFG_INITV], 2'b0};
          wrote_tcfg = True;
          if (val[`CSR_TCFG_EN] == 1 && val[`CSR_TCFG_INITV] == 0) begin
            timerInt[1] <= True;
          end
        end

        `CSR_TICLR: begin
          if (val[`CSR_TICLR_CLR] == 1) begin
            timerInt[1] <= False;
            cleared_timer_int = True;
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
      retireBookkeeping(wrote_tcfg, cleared_timer_int);
    endmethod

    method Action tlbwr;
      Bit#(3) tlbIndex = truncate(csr_tlbidx[`CSR_TLBIDX_INDEX]);
      Bool isNotExist = unpack(csr_tlbidx[`CSR_TLBIDX_NE]);
      tlb_ne[tlbIndex] <= isNotExist;
      if (isNotExist) begin
        tlb_ps[tlbIndex] <= 0;
        tlb_ehi[tlbIndex] <= 0;
        tlb_elo0[tlbIndex] <= 0;
        tlb_elo1[tlbIndex] <= 0;
        tlb_asid[tlbIndex] <= 0;
      end else begin
        tlb_ps[tlbIndex] <= csr_tlbidx[`CSR_TLBIDX_PS];
        tlb_ehi[tlbIndex] <= csr_tlbehi;
        tlb_elo0[tlbIndex] <= csr_tlbelo0;
        tlb_elo1[tlbIndex] <= csr_tlbelo1;
        tlb_asid[tlbIndex] <= csr_asid;
      end
      retireBookkeeping(False, False);
    endmethod

    method Action tlbrd;
      Bit#(3) tlbIndex = truncate(csr_tlbidx[`CSR_TLBIDX_INDEX]);
      Data next_tlbidx = zeroExtend(tlbIndex);
      if (tlb_ne[tlbIndex]) begin
        next_tlbidx[31] = 1'b1;
        csr_tlbehi <= 0;
        csr_tlbelo0 <= 0;
        csr_tlbelo1 <= 0;
      end else begin
        next_tlbidx[29:24] = tlb_ps[tlbIndex];
        csr_tlbehi <= tlb_ehi[tlbIndex];
        csr_tlbelo0 <= tlb_elo0[tlbIndex];
        csr_tlbelo1 <= tlb_elo1[tlbIndex];
        csr_asid <= (csr_asid & 32'hFFFFFC00) | (tlb_asid[tlbIndex] & 32'h000003FF);
      end
      csr_tlbidx <= next_tlbidx;
      retireBookkeeping(False, False);
    endmethod

    method ActionValue#(Addr) raiseException(Bit#(6) ecode, Bit#(9) esubcode, Addr pc, Addr badv);
      Data curCrmd = csr_crmd;
      Data nextCrmd = curCrmd;
      nextCrmd[`CSR_CRMD_PLV] = 2'b0;
      nextCrmd[`CSR_CRMD_IE] = 1'b0;

      Data nextPrmd = csr_prmd;
      nextPrmd[`CSR_PRMD_PPLV] = curCrmd[`CSR_CRMD_PLV];
      nextPrmd[`CSR_PRMD_PIE] = curCrmd[`CSR_CRMD_IE];

      Data nextEstat = csr_estat;
      nextEstat[`CSR_ESTAT_ECODE] = ecode;
      nextEstat[`CSR_ESTAT_ESUBCODE] = esubcode;

      csr_crmd <= nextCrmd;
      csr_prmd <= nextPrmd;
      csr_estat <= nextEstat;
      csr_era <= pc;
      if (ecode == `ECODE_ADE || ecode == `ECODE_ALE) begin
        csr_badv <= badv;
      end
      return csr_eentry;
    endmethod

    method ActionValue#(Addr) returnFromException;
      Data nextCrmd = csr_crmd;
      nextCrmd[`CSR_CRMD_PLV] = csr_prmd[`CSR_PRMD_PPLV];
      nextCrmd[`CSR_CRMD_IE] = csr_prmd[`CSR_PRMD_PIE];
      csr_crmd <= nextCrmd;
      retireBookkeeping(False, False);
      return csr_era;
    endmethod

    method ActionValue#(CpuToHostData) cpuToHost if (toHostFifo.notEmpty);
      let ret = toHostFifo.first;
      toHostFifo.deq;
      return ret;
    endmethod

    method Bool cpuToHostValid = toHostFifo.notEmpty;
  endmodule
