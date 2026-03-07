import Types::*;
import ProcTypes::*;
import Ehr::*;
import ConfigReg::*;
import Fifo::*;
import CsrAddr::*;

interface CsrFile;
  method Action start;
  method Bool started;
  method Data rd(CsrIndx idx);
  method Action wr(Maybe#(CsrIndx) idx, Data val);
  method ActionValue#(CpuToHostData) cpuToHost;
  method Bool cpuToHostValid;
endinterface

module mkCsrFile#(CoreID id)(CsrFile);
  Reg#(Bool) startReg <- mkReg(False);

  Reg#(Data) numInsts <- mkReg(0);
  Reg#(Data)   cycles <- mkReg(0);

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

  Reg#(Data) csr_save0 <- mkReg(0);
  Reg#(Data) csr_save1 <- mkReg(0);
  Reg#(Data) csr_save2 <- mkReg(0);
  Reg#(Data) csr_save3 <- mkReg(0);

  Reg#(Data)    csr_tid <- mkReg(0);
  Reg#(Data)    csr_tcfg <- mkReg(0);
  Ehr#(2, Data) csr_tval <- mkEhr(0); // port 0: timer rule, port 1: wr
  Ehr#(2, Bool) timerInt <- mkEhr(False); // port 0: timer rule, port 1: TICLR

  Reg#(Bool) llbit <- mkReg(False);
  Reg#(Bool) llbctlKlo <- mkReg(False);

  Reg#(Data) csr_ctag <- mkReg(0);
  Reg#(Data) csr_dmw0 <- mkReg(0);
  Reg#(Data) csr_dmw1 <- mkReg(0);

  rule count (startReg);
    cycles <= cycles + 1;
  endrule

  rule timerCount (startReg && csr_tcfg[`CSR_TCFG_EN] == 1
    && csr_tval[0] != 0);
    let next = csr_tval[0] - 1;
    if (next == 0) begin
      timerInt[0] <= True;
      if (csr_tcfg[`CSR_TCFG_PERIOD] == 1)
      csr_tval[0] <= {csr_tcfg[`CSR_TCFG_INITV], 2'b0};
      else
      csr_tval[0] <= 0;
    end else
    csr_tval[0] <= next;
  endrule

  method Action start if (!startReg);
    startReg <= True;
    cycles <= 0;
  endmethod

  method Bool started;
    return startReg;
  endmethod

  method Data rd(CsrIndx idx);
    return(case (idx)
      `CSR_CRMD: csr_crmd;
      `CSR_PRMD: csr_prmd;
      `CSR_EUEN: csr_euen;
      `CSR_ECFG: csr_ecfg;
      `CSR_ESTAT: csr_estat | (timerInt[1] ? 32'h00000800 : 0);
      `CSR_ERA: csr_era;
      `CSR_BADV: csr_badv;
      `CSR_EENTRY: csr_eentry;
      `CSR_TLBIDX: csr_tlbidx;
      `CSR_TLBEHI: csr_tlbehi;
      `CSR_TLBEL0: csr_tlbelo0;
      `CSR_TLBEL1: csr_tlbelo1;
      `CSR_ASID: csr_asid;
      `CSR_PGDL: csr_pgdl;
      `CSR_PGDH: csr_pgdh;
      `CSR_PGD: (csr_badv[31] == 1) ? csr_pgdh : csr_pgdl;
      `CSR_CPUID: zeroExtend(id);
      `CSR_SAVE0: csr_save0;
      `CSR_SAVE1: csr_save1;
      `CSR_SAVE2: csr_save2;
      `CSR_SAVE3: csr_save3;
      `CSR_TID: csr_tid;
      `CSR_TCFG: csr_tcfg;
      `CSR_TVAL: csr_tval[1];
      `CSR_TICLR: 0;
      `CSR_LLBCTL: {29'b0, pack(llbctlKlo), 1'b0, pack(llbit)};
      `CSR_TLBRENTRY: csr_tlbrentry;
      `CSR_CTAG: csr_ctag;
      `CSR_DMW0: csr_dmw0;
      `CSR_DMW1: csr_dmw1;
      csrMtohost: 0;
      default: 0;
    endcase);
  endmethod

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
        end

        `CSR_TICLR: begin
          if (val[`CSR_TICLR_CLR] == 1)
          timerInt[1] <= False;
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

        csrMtohost: begin
          Bit#(16) hi = truncateLSB(val);
          Bit#(16) lo = truncate(val);
          toHostFifo.enq(CpuToHostData {
            c2hType: unpack(truncate(hi)),
            data: lo
        });
          end
        endcase
      end
      numInsts <= numInsts + 1;
    endmethod

    method ActionValue#(CpuToHostData) cpuToHost;
      toHostFifo.deq;
      return toHostFifo.first;
    endmethod

    method Bool cpuToHostValid = toHostFifo.notEmpty;
  endmodule
