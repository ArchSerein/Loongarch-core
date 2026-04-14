import Types::*;
import Vector::*;
`include "CsrAddr.bsv"

typedef struct {
  Bool ne;
  Bit#(6) ps;
  Data ehi;
  Data elo0;
  Data elo1;
  Data asid;
} TlbReadResp deriving(Bits, Eq, FShow);

interface TlbArray;
  method Data searchResult(Data tlbehi, Data asid);
  method Action invtlb(Bit#(5) op, Data asidVal, Data vaVal);
  method Action writeEntry(Data tlbidx, Data tlbehi, Data tlbelo0, Data tlbelo1, Data asid);
  method Action fillEntry(Data tlbidx, Data tlbehi, Data tlbelo0, Data tlbelo1, Data asid);
  method TlbReadResp readEntry(Bit#(5) tlbIndex);
endinterface

function Bool tlbEntryGlobal(Data elo0, Data elo1);
  return (elo0[`CSR_TLBELO_G] == 1'b1) && (elo1[`CSR_TLBELO_G] == 1'b1);
endfunction

function Bool tlbVppnMatches(Bit#(6) ps, Data ehi, Data vaVal);
  Bool matched = False;
  if (ps == 6'd12) begin
    matched = ehi[`CSR_TLBEHI_VPPN] == vaVal[`CSR_TLBEHI_VPPN];
  end else begin
    matched = ehi[`CSR_TLBEHI_VPPN][18:9] == vaVal[`CSR_TLBEHI_VPPN][18:9];
  end
  return matched;
endfunction

function Bool tlbEntryMatches(Bit#(6) ps, Data ehi, Data asid, Data elo0, Data elo1, Data csrTlbehi, Data csrAsid);
  Bool globalEntry = tlbEntryGlobal(elo0, elo1);
  Bool sameVppn = tlbVppnMatches(ps, ehi, csrTlbehi);
  Bool sameAsid = asid[`CSR_ASID_ASID] == csrAsid[`CSR_ASID_ASID];
  return sameVppn && (globalEntry || sameAsid);
endfunction

function Bool tlbInvMatch(Bit#(5) op, Bit#(6) ps, Data ehi, Data asid, Data elo0, Data elo1,
    Data invAsid, Data invVa);
  Bool globalEntry = tlbEntryGlobal(elo0, elo1);
  Bool sameAsid = asid[`CSR_ASID_ASID] == invAsid[`CSR_ASID_ASID];
  Bool vppnMatch = tlbVppnMatches(ps, ehi, invVa);
  Bool matched = False;
  case (op)
    5'd0, 5'd1: matched = True;
    5'd2: matched = globalEntry;
    5'd3: matched = !globalEntry;
    5'd4: matched = !globalEntry && sameAsid;
    5'd5: matched = !globalEntry && sameAsid && vppnMatch;
    5'd6: matched = (globalEntry || sameAsid) && vppnMatch;
    default: matched = False;
  endcase
  return matched;
endfunction

(* synthesize *)
module mkTlb(TlbArray);
  Vector#(32, Reg#(Bool)) tlb_ne <- replicateM(mkReg(True));
  Vector#(32, Reg#(Bit#(6))) tlb_ps <- replicateM(mkRegU);
  Vector#(32, Reg#(Data)) tlb_ehi <- replicateM(mkRegU);
  Vector#(32, Reg#(Data)) tlb_elo0 <- replicateM(mkRegU);
  Vector#(32, Reg#(Data)) tlb_elo1 <- replicateM(mkRegU);
  Vector#(32, Reg#(Data)) tlb_asid <- replicateM(mkRegU);

  method Data searchResult(Data tlbehi, Data asid);
    Data next_tlbidx = 32'h80000000;
    Bool hit = False;
    for (Integer i = 0; i < 32; i = i + 1) begin
      Bit#(5) tlbIndex = fromInteger(i);
      if (!hit && !tlb_ne[tlbIndex] &&
          tlbEntryMatches(tlb_ps[tlbIndex], tlb_ehi[tlbIndex], tlb_asid[tlbIndex], tlb_elo0[tlbIndex], tlb_elo1[tlbIndex],
            tlbehi, asid)) begin
        next_tlbidx = zeroExtend(tlbIndex);
        hit = True;
      end
    end
    return next_tlbidx;
  endmethod

  method Action invtlb(Bit#(5) op, Data asidVal, Data vaVal);
    for (Integer i = 0; i < 32; i = i + 1) begin
      Bit#(5) tlbIndex = fromInteger(i);
      if (!tlb_ne[tlbIndex] &&
          tlbInvMatch(op, tlb_ps[tlbIndex], tlb_ehi[tlbIndex], tlb_asid[tlbIndex],
            tlb_elo0[tlbIndex], tlb_elo1[tlbIndex], asidVal, vaVal)) begin
        tlb_ne[tlbIndex] <= True;
      end
    end
  endmethod

  method Action writeEntry(Data tlbidx, Data tlbehi, Data tlbelo0, Data tlbelo1, Data asid);
    Bit#(5) tlbIndex = tlbidx[`CSR_TLBIDX_INDEX];
    Bool isNotExist = unpack(tlbidx[`CSR_TLBIDX_NE]);
    tlb_ne[tlbIndex] <= isNotExist;
    if (isNotExist) begin
      tlb_ps[tlbIndex] <= 0;
      tlb_ehi[tlbIndex] <= 0;
      tlb_elo0[tlbIndex] <= 0;
      tlb_elo1[tlbIndex] <= 0;
      tlb_asid[tlbIndex] <= 0;
    end else begin
      tlb_ps[tlbIndex] <= tlbidx[`CSR_TLBIDX_PS];
      tlb_ehi[tlbIndex] <= tlbehi;
      tlb_elo0[tlbIndex] <= tlbelo0;
      tlb_elo1[tlbIndex] <= tlbelo1;
      tlb_asid[tlbIndex] <= asid;
    end
  endmethod

  method Action fillEntry(Data tlbidx, Data tlbehi, Data tlbelo0, Data tlbelo1, Data asid);
    Bit#(5) tlbIndex = 0;
    Bool isNotExist = unpack(tlbidx[`CSR_TLBIDX_NE]);
    tlb_ne[tlbIndex] <= isNotExist;
    if (isNotExist) begin
      tlb_ps[tlbIndex] <= 0;
      tlb_ehi[tlbIndex] <= 0;
      tlb_elo0[tlbIndex] <= 0;
      tlb_elo1[tlbIndex] <= 0;
      tlb_asid[tlbIndex] <= 0;
    end else begin
      tlb_ps[tlbIndex] <= tlbidx[`CSR_TLBIDX_PS];
      tlb_ehi[tlbIndex] <= tlbehi;
      tlb_elo0[tlbIndex] <= tlbelo0;
      tlb_elo1[tlbIndex] <= tlbelo1;
      tlb_asid[tlbIndex] <= asid;
    end
  endmethod

  method TlbReadResp readEntry(Bit#(5) tlbIndex);
    return TlbReadResp{
      ne: tlb_ne[tlbIndex],
      ps: tlb_ps[tlbIndex],
      ehi: tlb_ehi[tlbIndex],
      elo0: tlb_elo0[tlbIndex],
      elo1: tlb_elo1[tlbIndex],
      asid: tlb_asid[tlbIndex]
    };
  endmethod
endmodule
