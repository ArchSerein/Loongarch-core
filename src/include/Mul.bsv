package Mul;

import Types::*;

interface Mul_ifc;
    method Action start(Bool is_signed, Bit#(32) src1, Bit#(32) src2);
    method Bit#(64) result();
    method Bool finish();
endinterface

(* synthesize *)
module mkMul(Mul_ifc);
    Reg#(Bit#(5)) counter <- mkReg(0);
    Reg#(Bit#(69)) p <- mkReg(0);
    Reg#(Bit#(69)) m_pos <- mkReg(0);
    Reg#(Bit#(69)) m_neg <- mkReg(0);

    rule step (counter > 0 && counter <= 17);
        Bit#(3) pr = p[2:0];
        Bit#(69) booth_add;
        if (pr == 3'b001 || pr == 3'b010)
            booth_add = m_pos;
        else if (pr == 3'b101 || pr == 3'b110)
            booth_add = m_neg;
        else if (pr == 3'b011)
            booth_add = (m_pos << 1);
        else if (pr == 3'b100)
            booth_add = (m_neg << 1);
        else
            booth_add = 0;

        Bit#(69) booth_sum = p + booth_add;
        Bit#(69) next_p = {booth_sum[68], booth_sum[68], booth_sum[68:2]};
        p <= next_p;
        counter <= counter + 1;
    endrule

    rule clear (counter == 18);
        counter <= 0;
    endrule

    method Action start(Bool is_signed, Bit#(32) src1, Bit#(32) src2) if (counter == 0);
        Bit#(34) src1_ext = is_signed ? {src1[31], src1[31], src1} : {2'b0, src1};
        Bit#(34) src2_ext = is_signed ? {src2[31], src2[31], src2} : {2'b0, src2};
        
        Bit#(34) neg_src1 = ~src1_ext + 1;

        Bit#(69) new_m_pos = {src1_ext, 35'b0};
        Bit#(69) new_m_neg = {neg_src1, 35'b0};

        m_pos <= new_m_pos;
        m_neg <= new_m_neg;
        
        p <= {34'b0, src2_ext, 1'b0};
        counter <= 1;
    endmethod

    method Bit#(64) result();
        return p[64:1];
    endmethod

    method Bool finish();
        return (counter[4] == 1 && counter[1] == 1);
    endmethod
endmodule

endpackage

