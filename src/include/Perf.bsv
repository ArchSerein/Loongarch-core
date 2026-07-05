`include "Autoconf.bsv"

`ifdef CONFIG_TRACE_PERFORMANCE

import "BDPI" function Action inst_count();
import "BDPI" function Action cycle_count();

import "BDPI" function Action perf_icache_miss();
import "BDPI" function Action perf_icache_miss_cycle();
import "BDPI" function Action perf_dcache_miss();
import "BDPI" function Action perf_dcache_miss_cycle();
import "BDPI" function Action perf_branch_mispredict_tage();
import "BDPI" function Action perf_branch_mispredict_fast();
import "BDPI" function Action perf_fetch_stall_cycle();
import "BDPI" function Action perf_dispatch_dependency_stall_cycle();
import "BDPI" function Action perf_memory_stall_cycle();

`endif