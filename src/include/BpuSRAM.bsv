import RegFile::*;
`include "Autoconf.bsv"

// ============================================================================
// Branch Predictor Unit SRAM Wrapper
// ============================================================================
// Single-port SRAM wrapper shared by MBtb / TAGE / ITTAGE. Provides a uniform
// 1-cycle read-latency storage abstraction so the predictor modules can use
// identical code for simulation (RegFile-based model) and FPGA (BVI SRAM IP).
//
// The underlying IP is vsrc/sram_128x64_wrap.v: 128-deep x 64-bit single-port
// RAM with byte write-enable. Each predictor table packs its entry into the
// low bits of the 64-bit word and zero-extends the address to 7 bits; tables
// smaller than 128 entries simply leave the upper addresses unused
// (addr[6] held to 0).
//
// Interface contract (matches the ICache tag/data SRAM pattern):
//   put(wea, addra, dina):
//     - wea == 0          : issue a read of addra (dout updates next cycle)
//     - wea != 0 (8'hFF)  : write dina to addra (dout also reflects dina)
//   read:
//     - returns the registered output (1-cycle latency from put)
//
// Scheduling (BVI branch mirrors ICache mkICacheTagSram):
//   (read) CF (read)    -- combinational read of output register
//   (put)  CF (read)    -- put and read do not conflict
//   (put)  C  (put)     -- single port: at most one put per cycle
// ============================================================================

interface BpuSram64;
    method Action put(Bit#(8) wea, Bit#(7) addra, Bit#(64) dina);
    method Bit#(64) read;
endinterface

`ifndef CONFIG_FPGA
// ---- Simulation model: RegFile + output register (1-cycle read latency) ----
// Behaviorally matches the BVI SRAM: read address is latched on put(wea=0),
// data appears on read() the following cycle. Writes honor byte enables and
// update the output register in the same cycle.
module mkBpuSram64(BpuSram64);
    RegFile#(Bit#(7), Bit#(64)) mem <- mkRegFileFull;
    Reg#(Bit#(64)) dout <- mkReg(0);

    method Action put(Bit#(8) wea, Bit#(7) addra, Bit#(64) dina);
        if (wea != 0) begin
            Bit#(64) cur = mem.sub(addra);
            Bit#(64) newv = cur;
            if (wea[0] == 1'b1) newv[ 7: 0] = dina[ 7: 0];
            if (wea[1] == 1'b1) newv[15: 8] = dina[15: 8];
            if (wea[2] == 1'b1) newv[23:16] = dina[23:16];
            if (wea[3] == 1'b1) newv[31:24] = dina[31:24];
            if (wea[4] == 1'b1) newv[39:32] = dina[39:32];
            if (wea[5] == 1'b1) newv[47:40] = dina[47:40];
            if (wea[6] == 1'b1) newv[55:48] = dina[55:48];
            if (wea[7] == 1'b1) newv[63:56] = dina[63:56];
            mem.upd(addra, newv);
            dout <= newv;
        end else begin
            dout <= mem.sub(addra);
        end
    endmethod

    method Bit#(64) read = dout;
endmodule
`else
// ---- FPGA: BVI import of sram_128x64_wrap ----
import "BVI" sram_128x64_wrap =
module mkBpuSram64(BpuSram64);
    default_clock clka(clka);
    default_reset no_reset;

    method put(wea, addra, dina) enable(ena);
    method douta read();

    schedule (read) CF (read);
    schedule (put)  CF (read);
    schedule (put)  C  (put);
endmodule
`endif
