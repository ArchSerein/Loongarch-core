// sram_128x64_wrap.v
// Inferred SRAM wrapper: 128 depth x 64 bits, Single Port RAM
// Byte write enable: 8 bytes of 8 bits each
// For Bluespec BVI import use

module sram_128x64_wrap (
    input           clka,
    input           ena,
    input  [ 7:0]   wea,
    input  [ 6:0]   addra,
    input  [63:0]   dina,
    output [63:0]   douta
);

    localparam V_STYLE = "block";
    localparam P_STYLE =    (V_STYLE == "ultra")        ? "uram" :
                            (V_STYLE == "distributed")  ? "select_ram" :
                            "block_ram";

    (*ram_style = V_STYLE*) reg [63:0] mem_reg [127:0]/*synthesis syn_ramstyle=P_STYLE*/;
    reg [63:0] output_buffer;

    always @(posedge clka) begin
        if (ena) begin
            if (wea) begin
                if (wea[0]) begin
                    mem_reg[addra][ 7: 0] <= dina[ 7: 0];
                end

                if (wea[1]) begin
                    mem_reg[addra][15: 8] <= dina[15: 8];
                end

                if (wea[2]) begin
                    mem_reg[addra][23:16] <= dina[23:16];
                end

                if (wea[3]) begin
                    mem_reg[addra][31:24] <= dina[31:24];
                end

                if (wea[4]) begin
                    mem_reg[addra][39:32] <= dina[39:32];
                end

                if (wea[5]) begin
                    mem_reg[addra][47:40] <= dina[47:40];
                end

                if (wea[6]) begin
                    mem_reg[addra][55:48] <= dina[55:48];
                end

                if (wea[7]) begin
                    mem_reg[addra][63:56] <= dina[63:56];
                end
            end
            else begin
                output_buffer <= mem_reg[addra];
            end
        end
    end

    assign douta = output_buffer;

endmodule
