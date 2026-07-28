import Ehr::*;
import Vector::*;
import GetPut::*;

//////////////////
// Fifo interface 

interface Fifo#(numeric type n, type t);
    method Bool notFull;
    method Action enq(t x);
    method Bool notEmpty;
    method Action deq;
    method t first;
    method Action clear;
endinterface

//////////////////////
// Conflict free fifo

module mkCFFifo( Fifo#(n, t) ) provisos (Bits#(t,tSz));
    // n is size of fifo
    // t is data type of fifo

    // storage elements
    Vector#(n, Reg#(t))     data     <- replicateM(mkRegU());
    Reg#(Bit#(TLog#(n)))    enqP     <- mkReg(0);
    Reg#(Bit#(TLog#(n)))    deqP     <- mkReg(0);
    Reg#(Bool)              empty    <- mkReg(True);
    Reg#(Bool)              full     <- mkReg(False);

    // requests
    Ehr#(3, Maybe#(t))      enqReq   <- mkEhr(tagged Invalid);
    Ehr#(3, Maybe#(Bool))   deqReq   <- mkEhr(tagged Invalid);
    Ehr#(2, Maybe#(Bool))   clearReq <- mkEhr(tagged Invalid);

    // useful value
    Bit#(TLog#(n))          max_index = fromInteger(valueOf(n)-1);

    // Update the state of the fifo to match any enqueue, dequeue, or clear
    // These attributes are statically checked by the compiler
    (* fire_when_enabled *)         // WILL_FIRE == CAN_FIRE
    (* no_implicit_conditions *)    // CAN_FIRE == guard (True)
    rule canonicalize;
        if( isValid(clearReq[1]) ) begin
            enqP <= 0;
            deqP <= 0;
            full <= False;
            empty <= True;
        end else begin
            let next_enqP = enqP;
            let next_deqP = deqP;
            let next_full = full;
            let next_empty = empty;

            if( isValid(enqReq[2]) ) begin
                data[enqP] <= fromMaybe(?, enqReq[2]);
                next_enqP = (enqP == max_index) ? 0 : enqP + 1;
            end
            if( isValid(deqReq[2]) ) begin
                next_deqP = (deqP == max_index) ? 0 : deqP + 1;
            end

            // compute next_full and next_empty
            if( next_deqP == next_enqP ) begin
                if( isValid(enqReq[2]) ) begin
                    // enqueued to full
                    next_full = True;
                end else if( isValid(deqReq[2]) ) begin
                    // dequeued to empty
                    next_empty = True;
                end else begin
                    // no deq or enq, so no change
                end
            end else begin
                // next_deqP != next_enqP so neither full nor empty
                next_full = False;
                next_empty = False;
            end

            enqP <= next_enqP;
            deqP <= next_deqP;
            full <= next_full;
            empty <= next_empty;
        end

        // clear pending requests
        clearReq[1] <= tagged Invalid;
        enqReq[2] <= tagged Invalid;
        deqReq[2] <= tagged Invalid;
    endrule

    method Bool notFull = !full;

    method Action enq(t x) if( !full );
        // Tell later stages an enqueue was requested
        enqReq[0] <= tagged Valid x;
    endmethod

    method Bool notEmpty = !empty;

    method Action deq if( !empty );
        // Tell later stages a dequeue was requested
        deqReq[0] <= tagged Valid True;
    endmethod

    method t first if( !empty );
        return data[deqP];
    endmethod

    method Action clear;
        // Clear any existing enq/deq requests
        // gets desired {enq, deq} < clear schedule
        enqReq[1] <= tagged Invalid;
        deqReq[1] <= tagged Invalid;
        // Tell later stages a clear was requested
        clearReq[0] <= tagged Valid True;
    endmethod
endmodule

////////////////////////////////
// instances of ToGet and ToPut

instance ToGet#( Fifo#(n, t), t ) provisos (Bits#(t, tsz));
    function Get#(t) toGet( Fifo#(n, t) fifo );
        return (interface Get#(t);
                    method ActionValue#(t) get();
                        let x = fifo.first;
                        fifo.deq;
                        return x;
                    endmethod
                endinterface);
    endfunction
endinstance

instance ToPut#( Fifo#(n, t), t ) provisos (Bits#(t, tsz));
    function Put#(t) toPut( Fifo#(n, t) fifo );
        return (interface Put#(t);
                    method Action put(t x);
                        fifo.enq(x);
                    endmethod
                endinterface);
    endfunction
endinstance
