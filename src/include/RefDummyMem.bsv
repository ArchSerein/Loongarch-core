import RefTypes::*;
import ProcTypes::*;
import Types::*;
import MemTypes::*;
import CacheTypes::*;
import GetPut::*;

(* synthesize *)
module mkRefDummyMem(RefMem);
	interface RefIMem iMem;
		method Action fetch(Addr pc, Instruction inst);
			noAction;
		endmethod
	endinterface

	interface RefDMem dMem;
		method Action issue(MemReq req);
			noAction;
		endmethod
		method Action commit(MemReq req, Maybe#(CacheLine) line, Maybe#(MemResp) resp);
			noAction;
		endmethod
	endinterface
endmodule
