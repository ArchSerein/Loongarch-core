import Types::*;
import ProcTypes::*;
import MemTypes::*;
import CacheTypes::*;
import Fifo::*;
import Vector::*;
import Memory::*;

function Bit#(TMul#(n,4)) wordEnToByteEn( Bit#(n) word_en );
    Bit#(TMul#(n,4)) byte_en;
    for( Integer i = 0 ; i < valueOf(n) ; i = i+1 ) begin
        for( Integer j = 0 ; j < 4 ; j = j+1 ) begin
            byte_en[ 4*i + j ] = word_en[i];
        end
    end
    return byte_en;
endfunction

function Bit#(wordSize) selectWord( Bit#(TMul#(numWords,wordSize)) line, Bit#(TLog#(numWords)) sel ) provisos ( Add#( a__, TLog#(numWords), TLog#(TMul#(numWords,wordSize))) );
    Bit#(TLog#(TMul#(numWords,wordSize))) index_offset = zeroExtend(sel) * fromInteger(valueOf(wordSize));
    return line[ index_offset + fromInteger(valueOf(wordSize)-1) : index_offset ];
endfunction

// 0100 -> 01000100
function Bit#(TMul#(wordSize,numWords)) replicateWord( Bit#(wordSize) word ) provisos ( Add#( a__, wordSize, TMul#(wordSize,numWords)) );
    Bit#(TMul#(wordSize,numWords)) x = 0;
    for( Integer i = 0 ; i < valueOf(numWords) ; i = i+1 ) begin
        x[ valueOf(wordSize)*(i+1) - 1 : valueOf(wordSize)*(i) ] = word;
    end
    return x;
endfunction

function WideMemReq toWideMemReq( MemReq req );
    Bit#(CacheLineWords) write_en = 0;
    CacheWordSelect wordsel = truncate( req.addr >> 2 );
    if( req.op == St ) begin
        write_en = 1 << wordsel;
    end
    Addr addr = req.addr;
    for( Integer i = 0 ; i < valueOf(TLog#(CacheLineBytes)) ; i = i+1 ) begin
        addr[i] = 0;
    end
    CacheLine data = replicate( req.data );

    return WideMemReq {
                write_en: write_en,
                addr: addr,
                data: data
            };
endfunction

function DDR3_Req toDDR3Req( MemReq req );
    Bool write = (req.op == St);
    CacheWordSelect wordSelect = truncate(req.addr >> 2);
    DDR3ByteEn byteen = wordEnToByteEn( 1 << wordSelect );
	if( req.op == Ld ) begin
		byteen = 0;
	end
    DDR3Addr addr = truncate( req.addr >> valueOf(TLog#(DDR3DataBytes)) );
    DDR3Data data = replicateWord(req.data);
    return DDR3_Req {
                write:      (req.op == St),
                byteen:     byteen,
                address:    addr,
                data:       data
            };
endfunction

module mkWideMemFromDDR3(   Fifo#(2, DDR3_Req) ddr3ReqFifo,
                            Fifo#(2, DDR3_Resp) ddr3RespFifo,
                            WideMem ifc );
    method Action req( WideMemReq x );
        Bool write_en = (x.write_en != 0);
        Bit#(DDR3DataBytes) byte_en = wordEnToByteEn(x.write_en);
		if( write_en == False ) begin
			byte_en = 0;
		end
        // x.addr is byte aligned and ddr3 addresses are aligned to DDR3Data sized blocks
        DDR3Addr addr = truncate(x.addr >> valueOf(TLog#(DDR3DataBytes)));

        DDR3_Req ddr3_req = DDR3_Req {
                                write:      write_en,
                                byteen:     byte_en,
                                address:    addr,
                                data:       pack(x.data)
                            };
        ddr3ReqFifo.enq( ddr3_req );
        $display("mkWideMemFromDDR3::req : wideMemReq.addr = 0x%0x, ddr3Req.address = 0x%0x, ddr3Req.byteen = 0x%0x", x.addr, ddr3_req.address, ddr3_req.byteen);
    endmethod
    method ActionValue#(WideMemResp) resp;
        let x = ddr3RespFifo.first;
        ddr3RespFifo.deq;
        $display("mkWideMemFromDDR3::resp : data = 0x%0x", x.data);
        return unpack(x.data);
    endmethod
	method Bool respValid = ddr3RespFifo.notEmpty;
endmodule

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

