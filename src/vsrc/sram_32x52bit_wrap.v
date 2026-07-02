// sram_32x52bit_wrap.v
// Inferred SRAM wrapper: 32 depth x 52 bits, Single Port RAM
// For Bluespec BVI import use

module sram_32x52bit_wrap (
    input           clka,
    input           ena,
    input           wea,
    input  [ 4:0]   addra,
    input  [51:0]   dina,
    output [51:0]   douta
);

    localparam V_STYLE = "block";
    localparam P_STYLE =    (V_STYLE == "ultra")        ? "uram" :
                            (V_STYLE == "distributed")  ? "select_ram" :
                            "block_ram";

    (*ram_style = V_STYLE*) reg [51:0] mem_reg [31:0]/*synthesis syn_ramstyle=P_STYLE*/;
    reg [51:0] output_buffer;

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
