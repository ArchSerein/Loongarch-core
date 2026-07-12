import Types::*;
import ProcTypes::*;
import Vector::*;
import Ehr::*;
import OoOTypes::*;
interface PRF;
  method Data rd1(PIndx p);
  method Data rd2(PIndx p);
  method Data rd3(PIndx p);
  method Data rd4(PIndx p);
  method Data rd5(PIndx p);
  method Action cdbWrite(PIndx p, Data v);
  method Action commitWrite(PIndx p, Data v);
  method Bool 	isReady(PIndx p);
  method Bool 	isReady2(PIndx p);
  method Action setReady(PIndx p);
  method Action setReadyCommit(PIndx p);
  method Action clearReady(PIndx p);
endinterface

(* synthesize *)
module mkPRF(PRF);
  // 只需 3 端口：[0]=Commit(释放/CSR), [1]=CDB(写回), [2]=所有读取
  Vector#(64, Ehr#(3, Data)) pregfile <- replicateM(mkEhr(0));
  
  // 对于 Ready 位：[0]=Commit / Allocate(Rename), [1]=CDB(写回), [2]=所有读取
  Vector#(64, Ehr#(3, Bool)) ready = newVector;
  for (Integer i = 0; i < 64; i = i + 1) begin
    ready[i] <- mkEhr(i < 32 ? True : False);
  end

  // ---------- 所有的读取都映射到最高的只读端口 2 ----------
  function Data read(PIndx p) = pregfile[p][2];
  method Data rd1(PIndx p) = read(p);
  method Data rd2(PIndx p) = read(p);
  method Data rd3(PIndx p) = read(p);
  method Data rd4(PIndx p) = read(p);
  method Data rd5(PIndx p) = read(p);
  method Bool isReady(PIndx p) = ready[p][2];
  method Bool isReady2(PIndx p) = ready[p][2];

  // ---------- 写入逻辑分配 ----------
  // Commit 阶段放在端口 0 (优先调度，反向流水线)
  method Action commitWrite(PIndx p, Data v);
    if (p != 0) pregfile[p][0] <= v;
  endmethod
  method Action setReadyCommit(PIndx p);
    if (p != 0) ready[p][0] <= True;
  endmethod
  // Rename 阶段 (Allocate) 也放在端口 0，因为一个物理寄存器不可能同周期既被Commit写又被Rename分配
  method Action clearReady(PIndx p);
    if (p != 0) ready[p][0] <= False;
  endmethod

  // CDB 写回放在端口 1
  method Action cdbWrite(PIndx p, Data v);
    if (p != 0) pregfile[p][1] <= v;
  endmethod
  method Action setReady(PIndx p);
    if (p != 0) ready[p][1] <= True;
  endmethod
endmodule
