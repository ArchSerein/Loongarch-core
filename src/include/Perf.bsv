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
import "BDPI" function Action perf_fpq_enq_fast();
import "BDPI" function Action perf_fpq_deq_fetch();
import "BDPI" function Action perf_fpq_full_cycles();
import "BDPI" function Action perf_fpq_confirmed_depth(Bit#(64) depth);
import "BDPI" function Action perf_fpq_unverified_depth(Bit#(64) depth);
import "BDPI" function Action perf_fetch_use_accurate();
import "BDPI" function Action perf_fetch_fast_fallback();
import "BDPI" function Action perf_accurate_started();
import "BDPI" function Action perf_accurate_match();
import "BDPI" function Action perf_accurate_override();
import "BDPI" function Action perf_accurate_obsolete_drop();
import "BDPI" function Action perf_accurate_truncated_entries();
import "BDPI" function Action perf_accurate_stale_drop();
import "BDPI" function Action perf_frontend_wait_fetch_cycles();
import "BDPI" function Action perf_frontend_wait_decode_cycles();

`endif
