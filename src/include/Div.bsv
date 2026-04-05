package Div;

import Types::*;

interface Div_ifc;
    method Action start(Bool is_signed, Bit#(32) dividend, Bit#(32) divisor);
    method Bit#(64) result();
    method Bool finish();
endinterface

(* synthesize *)
module mkDiv(Div_ifc);
    Reg#(Bit#(6)) counter <- mkReg(0);
    Reg#(Bit#(33)) partial_rem <- mkReg(0);
    Reg#(Bit#(32)) div_pos <- mkReg(0);
    Reg#(Bit#(32)) div_neg <- mkReg(0);
    Reg#(Bit#(32)) quotient <- mkReg(0);
    Reg#(Bool) sign_q <- mkReg(False);
    Reg#(Bool) sign_r <- mkReg(False);

    rule step (counter > 0 && counter < 33);
        Bit#(33) partial_rem_val = {partial_rem[31:0], quotient[31]};
        Bit#(33) partial_rem_add = ~partial_rem[32] == 1 ? {1'b1, div_neg} : {1'b0, div_pos};
        Bit#(33) next_partial_rem_step = partial_rem_val + partial_rem_add;
        Bit#(32) quotient_val = {quotient[30:0], 1'b0};
        Bit#(32) next_quotient = {quotient_val[31:1], ~next_partial_rem_step[32]};
        
        partial_rem <= next_partial_rem_step;
        quotient <= next_quotient;
        counter <= counter + 1;
    endrule

    rule fix_rem (counter == 33);
        Bit#(33) next_partial_rem_fix = partial_rem[32] == 1 ? (partial_rem + {1'b0, div_pos}) : partial_rem;
        partial_rem <= next_partial_rem_fix;
        counter <= counter + 1;
    endrule

    rule clear (counter == 34);
        counter <= 0;
    endrule

    method Action start(Bool is_signed, Bit#(32) dividend, Bit#(32) divisor) if (counter == 0);
        Bit#(1) dividend_sign = dividend[31];
        Bit#(1) divisor_sign = divisor[31];
        
        Bool q_sign = is_signed ? unpack(dividend_sign ^ divisor_sign) : False;
        Bool r_sign = is_signed ? unpack(dividend_sign) : False;

        Bit#(32) dvd_abs = (is_signed && dividend_sign == 1) ? (~dividend + 1) : dividend;
        Bit#(32) div_abs = (is_signed && divisor_sign == 1) ? (~divisor + 1) : divisor;

        sign_q <= q_sign;
        sign_r <= r_sign;
        
        div_pos <= div_abs;
        div_neg <= ~div_abs + 1;
        partial_rem <= 0;
        quotient <= dvd_abs;
        
        counter <= 1;
    endmethod

    method Bit#(64) result();
        Bit#(32) final_q = sign_q ? (~quotient + 1) : quotient;
        Bit#(32) final_r = sign_r ? (~partial_rem[31:0] + 1) : partial_rem[31:0];
        return {final_r, final_q};
    endmethod

    method Bool finish();
        return (counter == 34);
    endmethod

endmodule

endpackage
