import MemTypes::*;
import Types::*;
import Vector::*;
`include "Autoconf.bsv"

// Maximum number of words in one memory burst transaction.
typedef `CONFIG_MEM_BURST_WORDS MemBurstWords;

typedef Bit#(MemBurstWords)            MemWriteEn;
typedef Vector#(MemBurstWords, Data)   WideMemResp;

typedef struct {
  // One bit per word beat in the burst. All-zero means read request.
  MemWriteEn    write_en;
  Addr          addr;
  WideMemResp   data;
  Bit#(8)       burst_len;  // number of words in burst, valid: 1..MemBurstWords
} WideMemReq deriving(Eq, Bits);

interface WideMem;
  method Action req(WideMemReq r);
  method ActionValue#(WideMemResp) resp;
  method Bool respValid;
endinterface

// Interface for caches
interface ICache;
  method Action req(Addr a);
  method ActionValue#(Instruction) resp;
endinterface

interface DCache;
  method Action req(MemReq r);
  method ActionValue#(Data) resp;
endinterface

typedef 16 StQSize;
