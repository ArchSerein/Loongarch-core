import Vector::*;
import Fifo::*;

import Types::*;
import ProcTypes::*;
import MemTypes::*;
import CacheTypes::*;
import RefDummyMem::*;
import MemUtil::*;
import RefTypes::*;
import Core::*;

typedef 20 TbWordAddrSz;
typedef Bit#(TbWordAddrSz) TbWordAddr;
typedef 1000000 TbMaxCycles;

import "BDPI" function ActionValue#(Bit#(64)) c_createTbMem(Bit#(32)
  wordAddrWidth);
import "BDPI" function Action c_loadTbMem(Bit#(64) memPtr);
import "BDPI" function ActionValue#(Data) c_readTbMem(Bit#(64) memPtr, Bit#(32)
  wordAddr);
import "BDPI" function Action c_writeTbMem(Bit#(64) memPtr, Bit#(32) wordAddr,
  Data d);

function Bool inTbMemRange(Bit#(TSub#(AddrSz, 2)) wordAddr);
  TbWordAddr narrowAddr = truncate(wordAddr);
  return zeroExtend(narrowAddr) == wordAddr;
endfunction

module mkTbWideMem(WideMem);
  Fifo#(2, CacheLine) respQ <- mkCFFifo;
  Reg#(Bit#(64)) memPtr <- mkReg(0);
  Reg#(Bool) memReady <- mkReg(False);

  rule initMem (!memReady);
    let ptr <- c_createTbMem(fromInteger(valueOf(TbWordAddrSz)));
    if (ptr == 0) begin
      $fwrite(stderr, "TB: failed to create simulation memory\n");
      $finish(1);
    end
    c_loadTbMem(ptr);
    memPtr <= ptr;
    memReady <= True;
  endrule

  method Action req(WideMemReq r) if (memReady);
    Bit#(TSub#(AddrSz, 2)) baseWordAddr = truncateLSB(r.addr);
    for (Integer i = 0; i < valueOf(TLog#(CacheLineWords)); i = i + 1) begin
      baseWordAddr[i] = 0;
    end

    if (!inTbMemRange(baseWordAddr)) begin
      $fwrite(stderr, "TB: wide memory access out of range: %08x\n", r.addr);
      $finish(1);
    end
    else begin
      TbWordAddr wordIdx = truncate(baseWordAddr);

      if (r.write_en == 0) begin
        CacheLine line = ?;
        for (Integer i = 0; i < valueOf(CacheLineWords); i = i + 1) begin
          Bit#(32) readAddr = zeroExtend(wordIdx) + fromInteger(i);
          line[i] <- c_readTbMem(memPtr, readAddr);
        end
        respQ.enq(line);
      end
      else begin
        for (Integer i = 0; i < valueOf(CacheLineWords); i = i + 1) begin
          if (r.write_en[i] == 1) begin
            Bit#(32) writeAddr = zeroExtend(wordIdx) + fromInteger(i);
            c_writeTbMem(memPtr, writeAddr, r.data[i]);
          end
        end
      end
    end
  endmethod

  method ActionValue#(CacheLine) resp;
    let line = respQ.first;
    respQ.deq;
    return line;
  endmethod

  method Bool respValid = respQ.notEmpty;
endmodule

(* synthesize *)
module mkTb(Empty);
  Reg#(Bool) started <- mkReg(False);
  Reg#(Bit#(16)) printIntLow <- mkReg(0);
  Reg#(Bit#(64)) cycles <- mkReg(0);
  WideMem wideMemWrapper <- mkTbWideMem;
  SplitWideMem2 splitWideMem <- mkSplitWideMem2(started, wideMemWrapper);
  RefMem refMem <- mkRefDummyMem;
  Core core <- mkCore(splitWideMem.iMem, splitWideMem.dMem, refMem.dMem);

  rule boot (!started);
    started <= True;
    core.hostToCpu(0);
  endrule

  rule countCycles (started);
    cycles <= cycles + 1;
    if (cycles == fromInteger(valueOf(TbMaxCycles) - 1)) begin
      $fwrite(stderr, "TB: timeout after %0d cycles\n", valueOf(TbMaxCycles));
      $finish(1);
    end
  endrule

  rule drainCpuToHost (started && core.cpuToHostValid);
    let msg <- core.cpuToHost;
    case (msg.c2hType)
      ExitCode: begin
	Bit#(32) code = zeroExtend(msg.data);
        $display("TB: exit code %0d after %0d cycles", code, cycles);
        $finish(0);
      end
      PrintChar: begin
	Bit#(8) char = truncate(msg.data);
        $write("%c", char);
      end
      PrintIntLow: begin
        printIntLow <= msg.data;
      end
      PrintIntHigh: begin
        $display("%0d", {msg.data, printIntLow});
      end
    endcase
  endrule
endmodule
