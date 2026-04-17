import Types::*;
import ProcTypes::*;
import CoreTypes::*;
`include "CsrAddr.bsv"

function ExcpInfo mkNoExcp;
  return ExcpInfo{valid: False, ecode: 0, esubcode: 0, badv: 0};
endfunction

function ExcpInfo mkExcp(Bit#(6) ecode, Bit#(9) esubcode, Addr badv);
  return ExcpInfo{valid: True, ecode: ecode, esubcode: esubcode, badv: badv};
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

function Bool coreIsFetchAddrLegal(Addr a);
  return (a[31:24] == 8'h1c) || (a[31:24] == 8'h00) ||
    (a[31:24] == 8'h80) || (a[31:24] == 8'ha0);
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
