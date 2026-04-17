import Types::*;
import Tlb::*;
`include "CsrAddr.bsv"

typedef enum {
  MmuFetch,
  MmuLoad,
  MmuStore
} MmuAccessType deriving(Bits, Eq);

typedef struct {
  Addr    pa;
  Bit#(2) mat;
  Bool    fromDirect;
  Bool    fromDmw;
  Bool    fromTlb;
  Bool    excValid;
  Bit#(6) ecode;
  Bit#(9) esubcode;
  Addr    badv;
} MmuResult deriving(Bits, Eq);

function Bool mmuIsFetch(MmuAccessType t);
  return t == MmuFetch;
endfunction

function Bool mmuIsStore(MmuAccessType t);
  return t == MmuStore;
endfunction

function Bit#(9) mmuAdeSubcode(MmuAccessType t);
  return mmuIsFetch(t) ? `ESUBCODE_ADEF : `ESUBCODE_ADEM;
endfunction

function Bool mmuDmwMatch(Data dmw, Addr va, Bit#(2) plv);
  Bool plv0Ok = (plv == 2'b00) && (dmw[`CSR_DMW_PLV0] == 1'b1);
  Bool plv3Ok = (plv == 2'b11) && (dmw[`CSR_DMW_PLV3] == 1'b1);
  return (plv0Ok || plv3Ok) && (va[`CSR_DMW_VSEG] == dmw[`CSR_DMW_VSEG]);
endfunction

function Addr mmuDmwTranslate(Data dmw, Addr va);
  return { dmw[`CSR_DMW_PSEG], va[28:0] };
endfunction

function Addr mmuComposePa(Bit#(20) ppn, Bit#(6) ps, Addr va);
  Bit#(32) shiftVal = zeroExtend(ps);
  Bit#(32) pageMask = (32'b1 << shiftVal) - 32'b1;
  Bit#(32) ppnBase = zeroExtend(ppn) << 12;
  return (ppnBase & ~pageMask) | (va & pageMask);
endfunction

function MmuResult mmuTranslate(Addr va, MmuAccessType accessType, Data crmd,
    Data asid, Data dmw0, Data dmw1, TlbLookupResult tlbLookup);
  Bool isFetch = mmuIsFetch(accessType);
  Bool isStore = mmuIsStore(accessType);
  Bool da = (crmd[`CSR_CRMD_DA] == 1'b1);
  Bool pg = (crmd[`CSR_CRMD_PG] == 1'b1);
  Bit#(2) plv = crmd[`CSR_CRMD_PLV];

  MmuResult result = MmuResult{
    pa: 0,
    mat: 0,
    fromDirect: False,
    fromDmw: False,
    fromTlb: False,
    excValid: False,
    ecode: 0,
    esubcode: 0,
    badv: va
  };

  if (da && !pg) begin
    result.pa = va;
    result.mat = isFetch ? crmd[`CSR_CRMD_DATF] : crmd[`CSR_CRMD_DATM];
    result.fromDirect = True;
  end else if (!da && pg) begin
    Bool dmw0Hit = mmuDmwMatch(dmw0, va, plv);
    Bool dmw1Hit = !dmw0Hit && mmuDmwMatch(dmw1, va, plv);

    if (dmw0Hit || dmw1Hit) begin
      Data hitDmw = dmw0Hit ? dmw0 : dmw1;
      result.pa = mmuDmwTranslate(hitDmw, va);
      result.mat = hitDmw[`CSR_DMW_MAT];
      result.fromDmw = True;
    end else if (!tlbLookup.found) begin
      result.excValid = True;
      result.ecode = `ECODE_TLBR;
    end else if (!tlbLookup.v) begin
      result.excValid = True;
      if (isFetch)
        result.ecode = `ECODE_PIF;
      else if (isStore)
        result.ecode = `ECODE_PIS;
      else
        result.ecode = `ECODE_PIL;
    end else if (plv > tlbLookup.plv) begin
      result.excValid = True;
      result.ecode = `ECODE_PPI;
    end else if (isStore && !tlbLookup.d) begin
      result.excValid = True;
      result.ecode = `ECODE_PME;
    end else begin
      result.pa = mmuComposePa(tlbLookup.ppn, tlbLookup.ps, va);
      result.mat = tlbLookup.mat;
      result.fromTlb = True;
    end
  end else begin
    result.excValid = True;
    result.ecode = `ECODE_ADE;
    result.esubcode = mmuAdeSubcode(accessType);
  end

  return result;
endfunction
