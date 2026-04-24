import Types::*;
import ProcTypes::*;
import CoreTypes::*;
import CsrAddr::*;
`include "CsrAddr.bsv"

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

function Bool matUseCache(MatType mat);
  return mat == Cc;
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

function Bit#(WordSz) coreLoadByteEn(Bit#(2) offset, Bit#(4) rawEn);
  Bit#(2) alignOff = 0;
  Bit#(WordSz) byteEn = 0;
  case (rawEn)
    4'b0001: begin
      alignOff = offset;
      byteEn = 4'b0001 << alignOff;
    end
    4'b0011: begin
      alignOff = {offset[1], 1'b0};
      byteEn = 4'b0011 << alignOff;
    end
    4'b1111: begin
      byteEn = 4'b1111;
    end
    default: begin
      byteEn = 4'b0000;
    end
  endcase
  return byteEn;
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

function Bool coreIsTimerRelatedCsr(CsrIndx idx);
  return idx == `CSR_TCFG || idx == `CSR_TVAL || idx == `CSR_TICLR ||
    idx == `CSR_ESTAT;
endfunction

function Tuple3#(Data, Data, Data) coreInterruptCsrView(
  Maybe#(CsrIndx) csrIdx, Data writeVal, Data curCrmd, Data curEcfg,
  Data curEstat);
  Data nextCrmd = curCrmd;
  Data nextEcfg = curEcfg;
  Data nextEstat = curEstat;

  if (csrIdx matches tagged Valid .idx) begin
    case (idx)
      `CSR_CRMD: nextCrmd = (writeVal & 32'h000001FF) | (curCrmd & 32'hFFFFFE00);
      `CSR_ECFG: nextEcfg = (writeVal & 32'h00001BFF) | (curEcfg & 32'hFFFFE400);
      `CSR_ESTAT: nextEstat = (writeVal & 32'h00000003) | (curEstat & 32'hFFFFFFFC);
      `CSR_TCFG: begin
        if (writeVal[`CSR_TCFG_EN] == 1'b1 && writeVal[`CSR_TCFG_INITV] == 0) begin
          nextEstat = curEstat | 32'h00000800;
        end
      end
      `CSR_TICLR: begin
        if (writeVal[`CSR_TICLR_CLR] == 1'b1) begin
          nextEstat = curEstat & 32'hFFFFF7FF;
        end
      end
      default: nextCrmd = nextCrmd;
    endcase
  end

  return tuple3(nextCrmd, nextEcfg, nextEstat);
endfunction

function Data corePendingInterruptBits(Data ecfg, Data estat);
  return estat & ecfg & 32'h00001fff;
endfunction

function Bool coreHasInterrupt(Data crmd, Data ecfg, Data estat);
  return crmd[`CSR_CRMD_IE] == 1'b1 && corePendingInterruptBits(ecfg, estat) != 0;
endfunction

function Bool coreIsCsrConflict(Maybe#(CsrIndx) pendingWrite, Maybe#(CsrIndx) curAccess);
  if (pendingWrite matches tagged Valid .w &&& curAccess matches tagged Valid .a) begin
    Bool sameCsr = (w == a);
    Bool timerSideEffectConflict = coreIsTimerRelatedCsr(w) && coreIsTimerRelatedCsr(a);
    return sameCsr || timerSideEffectConflict;
  end else begin
    return False;
  end
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