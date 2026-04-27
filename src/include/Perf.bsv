`include "Autoconf.bsv"

`ifdef CONFIG_TRACE_PERFORMANCE

import "BDPI" function Action inst_count();
import "BDPI" function Action cycle_count();

import "BDPI" function Action perf_icache_miss();
import "BDPI" function Action perf_icache_miss_cycle();
import "BDPI" function Action perf_dcache_miss();
import "BDPI" function Action perf_dcache_miss_cycle();
import "BDPI" function Action perf_branch_exec(Bool mispredict);
import "BDPI" function Action perf_pipeline_stall(Bit#(3) stage); // 0: IF, 1: ID/RR, 2: EXE, 3: MEM

`endif