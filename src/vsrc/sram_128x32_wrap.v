// sram_128x32_wrap.v
// Inferred SRAM wrapper: 128 depth x 32 bits, Single Port RAM
// For Bluespec BVI import use

module sram_128x32_wrap (
    input           clka,
    input           ena,
    input           wea,
    input  [ 6:0]   addra,
    input  [31:0]   dina,
    output [31:0]   douta
);

    localparam V_STYLE = "block";
    localparam P_STYLE =    (V_STYLE == "ultra")        ? "uram" :
                            (V_STYLE == "distributed")  ? "select_ram" :
                            "block_ram";

    (*ram_style = V_STYLE*) reg [31:0] mem_reg [127:0]/*synthesis syn_ramstyle=P_STYLE*/;
    reg [31:0] output_buffer;

    always @(posedge clka) begin
        if (ena) begin
            if (wea) begin
                mem_reg[addra] <= dina;
            end
            else begin
                output_buffer <= mem_reg[addra];
            end
        end
    end

    assign douta = output_buffer;

endmodule
