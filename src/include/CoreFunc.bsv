`include "Autoconf.bsv"
`include "CsrAddr.bsv"
import Types::*;
import ProcTypes::*;
import CoreTypes::*;
import OoOTypes::*;
import CsrAddr::*;
`ifdef CONFIG_DIFFTEST
import DiffTypes::*;
`endif

function ExcpInfo mkNoExcp;
  return ExcpInfo{valid: False, ecode: 0, esubcode: 0, badv: 0};
endfunction

function ExcpInfo mkExcp(Bit#(6) ecode, Bit#(9) esubcode, Addr badv);
  return ExcpInfo{valid: True, ecode: ecode, esubcode: esubcode, badv: badv};
endfunction

function MmuTranslateType getMmuTranslateType(Data crmd);
  Bit#(2) mode = {crmd[`CSR_CRMD_DA], crmd[`CSR_CRMD_PG]};
  case (mode)
    2'b10: return Direct;
    2'b01: return Translate;
    default: return None;
  endcase
endfunction

function MatType getFetchMatType(Data crmd);
  return unpack(crmd[`CSR_CRMD_DATF]);
endfunction

function MatType getDataMatType(Data crmd);
  return unpack(crmd[`CSR_CRMD_DATM]);
endfunction

function Bool matUseCache(MmuTranslateType transType, MatType mat, Data crmd,
                          MmuAccessType accessType);
  if (accessType == MmuFetch) begin
    if (transType == Direct) return getFetchMatType(crmd) == Cc;
    else return mat == Cc;
  end else begin
    if (transType == Direct) return getDataMatType(crmd) == Cc;
    else return mat == Cc;
  end
endfunction

function Data coreApplyByteMask(Data oldData, Data newData, Bit#(WordSz) byteEn);
  Data merged = oldData;
  for (Integer i = 0; i < valueOf(WordSz); i = i + 1) begin
    if (byteEn[i] == 1'b1) begin
      Bit#(8) b = newData[(8 * i) + 7 : (8 * i)];
      merged[(8 * i) + 7 : (8 * i)] = b;
    end
  end
  return merged;
endfunction

function Bool coreSameWordAddr(Addr a, Addr b);
  Bit#(TSub#(AddrSz, 2)) wordA = truncateLSB(a);
  Bit#(TSub#(AddrSz, 2)) wordB = truncateLSB(b);
  return wordA == wordB;
endfunction

// Helper functions for optimization
function Data selectLoadData(Data rData, Bit#(2) offset, Bit#(4) rawEn, Bool signExt);
  Bit#(2) loadOffset = 2'b00;
  case (rawEn)
    4'b0001: loadOffset = offset;
    4'b0011: loadOffset = {offset[1], 1'b0};
    default: loadOffset = 2'b00;
  endcase

  Data shiftedData = rData >> {loadOffset, 3'b0};

  if (rawEn == 4'b0001) begin
    return signExt ? signExtend(shiftedData[7:0]) : zeroExtend(shiftedData[7:0]);
  end else if (rawEn == 4'b0011) begin
    return signExt ? signExtend(shiftedData[15:0]) : zeroExtend(shiftedData[15:0]);
  end else begin
    return shiftedData;
  end
endfunction

function Tuple2#(Bit#(4), Data) selectStoreData(Data d, Bit#(2) offset, Bit#(4) rawEn);
  Bit#(2) alignOff = 0;
  Bit#(4) byteEn = 0;
  Data wData = 0;

  case (rawEn)
    4'b0001: begin
      alignOff = offset;
      byteEn = 4'b0001 << alignOff;
      wData = zeroExtend(d[7:0]) << {alignOff, 3'b0};
    end
    4'b0011: begin
      alignOff = {offset[1], 1'b0};
      byteEn = 4'b0011 << alignOff;
      wData = zeroExtend(d[15:0]) << {alignOff, 3'b0};
    end
    4'b1111: begin
      alignOff = 2'b00;
      byteEn = 4'b1111;
      wData = d;
    end
    default: begin
      alignOff = 2'b00;
      byteEn = 4'b0000;
      wData = 0;
    end
  endcase
  return tuple2(byteEn, wData);
endfunction

function Bool coreIsBarrier(IType t);
  return t == Dbar || t == Ibar;
endfunction

function Data mkInterruptNo(Data estat);
  Bit#(12) intr = {estat[`CSR_ESTAT_IS_3], estat[`CSR_ESTAT_IS_2],
  estat[`CSR_ESTAT_IS_1], estat[`CSR_ESTAT_IS_0]};
    Data intNo = 0;
  if      (intr[11] == 1'b1) intNo = 12; // ESTAT[12]
  else if (intr[10] == 1'b1) intNo = 11; // ESTAT[11]
  else if (intr[9] == 1'b1)  intNo = 9;  // ESTAT[9]
  else if (intr[8] == 1'b1)  intNo = 8;  // ESTAT[8]
  else if (intr[7] == 1'b1)  intNo = 7;  // ESTAT[7]
  else if (intr[6] == 1'b1)  intNo = 6;  // ESTAT[6]
  else if (intr[5] == 1'b1)  intNo = 5;  // ESTAT[5]
  else if (intr[4] == 1'b1)  intNo = 4;  // ESTAT[4]
  else if (intr[3] == 1'b1)  intNo = 3;  // ESTAT[3]
  else if (intr[2] == 1'b1)  intNo = 2;  // ESTAT[2]
  else if (intr[1] == 1'b1)  intNo = 1;  // ESTAT[1]
  else if (intr[0] == 1'b1)  intNo = 0;  // ESTAT[0]
  
  return intNo;
endfunction

function ExcpInfo checkMemHasExcp(Maybe#(ByteMask) mask, Addr addr, ExcpInfo excp);
  ByteMask m = fromMaybe(5'b00000, mask);
  if (!excp.valid) begin
    Bit#(4) rawEn = m[3:0];
    Bool exAle = False;
    if (rawEn == 4'b0011) begin
      exAle = (addr[0] != 1'b0);
    end else if (rawEn == 4'b1111) begin
      exAle = (addr[1:0] != 2'b00);
    end
    if (exAle) excp = mkExcp(`ECODE_ALE, `ESUBCODE_NONE, addr);
  end
  return excp;
endfunction

// Rename-stage helper
function Bool renameNeedsFree(D2RN r);
  return !r.excp.valid && isValid(normalizeReg(r.dInst.dst));
endfunction

// Dispatch-stage helpers
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

// Issue-stage helpers
function Bool isMulFunc(MulDivFunc f);
  return f == MulW || f == MulhW || f == MulhWu;
endfunction

function Bool isDivFunc(MulDivFunc f);
  return f == DivW || f == DivWu || f == ModW || f == ModWu;
endfunction

`ifdef CONFIG_DIFFTEST
// Commit-stage helper: read CSR value from snapshot
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
`endif
