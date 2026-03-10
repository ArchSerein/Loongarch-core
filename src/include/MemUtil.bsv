import Types::*;
import ProcTypes::*;
import MemTypes::*;
import CacheTypes::*;
import Fifo::*;
import Vector::*;
import Memory::*;

interface SplitWideMem2;
    interface WideMem dMem;
    interface WideMem iMem;
endinterface

// Fixed two-port splitter for single-core designs:
// dMem (load/store) has priority over iMem (instruction fetch).
module mkSplitWideMem2(Bool initDone, WideMem mem, SplitWideMem2 ifc);
    Fifo#(2, WideMemReq) dReqFifo <- mkCFFifo;
    Fifo#(2, WideMemReq) iReqFifo <- mkCFFifo;
    Fifo#(3, Bool) reqSource <- mkCFFifo; // True: dMem, False: iMem
    Fifo#(2, WideMemResp) dRespFifo <- mkCFFifo;
    Fifo#(2, WideMemResp) iRespFifo <- mkCFFifo;

    rule doMemReq(initDone);
        if (dReqFifo.notEmpty) begin
            let req = dReqFifo.first;
            dReqFifo.deq;
            mem.req(req);
            if (req.write_en == 0) begin
                reqSource.enq(True);
            end
        end
        else if (iReqFifo.notEmpty) begin
            let req = iReqFifo.first;
            iReqFifo.deq;
            mem.req(req);
            if (req.write_en == 0) begin
                reqSource.enq(False);
            end
        end
    endrule

    rule doMemResp(initDone);
        let resp <- mem.resp;
        let source = reqSource.first;
        reqSource.deq;

        if (source) begin
            dRespFifo.enq(resp);
        end
        else begin
            iRespFifo.enq(resp);
        end
    endrule

    interface WideMem dMem;
        method Action req(WideMemReq x);
            dReqFifo.enq(x);
        endmethod
        method ActionValue#(WideMemResp) resp;
            let x = dRespFifo.first;
            dRespFifo.deq;
            return x;
        endmethod
        method Bool respValid = dRespFifo.notEmpty;
    endinterface

    interface WideMem iMem;
        method Action req(WideMemReq x);
            iReqFifo.enq(x);
        endmethod
        method ActionValue#(WideMemResp) resp;
            let x = iRespFifo.first;
            iRespFifo.deq;
            return x;
        endmethod
        method Bool respValid = iRespFifo.notEmpty;
    endinterface
endmodule

