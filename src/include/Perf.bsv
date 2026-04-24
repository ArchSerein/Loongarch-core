`include "Autoconf.bsv"

`ifdef CONFIG_TRACE_PERFORMANCE

import "BDPI" function Action inst_count();
import "BDPI" function Action cycle_count();

`endif