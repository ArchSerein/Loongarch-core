#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <string>

#include <verilated.h>
#include "VmkTb.h"

#if VM_TRACE
#include <verilated_vcd_c.h>
#endif

namespace {

struct Options {
  std::uint64_t max_cycles = 1000000;
  bool trace = false;
  std::string trace_path = "build/wave.vcd";
};

Options parse_args(int argc, char** argv) {
  Options opts;
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--trace") == 0) {
      opts.trace = true;
      continue;
    }
    if (std::strcmp(argv[i], "--max-cycles") == 0 && (i + 1) < argc) {
      opts.max_cycles = std::strtoull(argv[++i], nullptr, 0);
      continue;
    }
    if (std::strcmp(argv[i], "--trace-path") == 0 && (i + 1) < argc) {
      opts.trace_path = argv[++i];
      continue;
    }
    std::cerr << "unknown argument: " << argv[i] << '\n';
    std::exit(2);
  }
  return opts;
}

void tick(VmkTb& top, vluint64_t& main_time
#if VM_TRACE
          ,
          VerilatedVcdC* tfp
#endif
) {
  top.CLK = 0;
  top.eval();
#if VM_TRACE
  if (tfp != nullptr) {
    tfp->dump(main_time);
  }
#endif
  ++main_time;

  top.CLK = 1;
  top.eval();
#if VM_TRACE
  if (tfp != nullptr) {
    tfp->dump(main_time);
  }
#endif
  ++main_time;
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  const Options opts = parse_args(argc, argv);

  auto top = std::make_unique<VmkTb>();
  vluint64_t main_time = 0;

#if VM_TRACE
  std::unique_ptr<VerilatedVcdC> tfp;
  if (opts.trace) {
    Verilated::traceEverOn(true);
    tfp = std::make_unique<VerilatedVcdC>();
    top->trace(tfp.get(), 99);
    tfp->open(opts.trace_path.c_str());
  }
#endif

  top->RST_N = 0;
  tick(*top, main_time
#if VM_TRACE
       ,
       tfp.get()
#endif
  );
  tick(*top, main_time
#if VM_TRACE
       ,
       tfp.get()
#endif
  );
  top->RST_N = 1;

  std::uint64_t cycles = 0;
  while (!Verilated::gotFinish() && cycles < opts.max_cycles) {
    tick(*top, main_time
#if VM_TRACE
         ,
         tfp.get()
#endif
    );
    ++cycles;
  }

  if (!Verilated::gotFinish()) {
    std::cerr << "simulation stopped after reaching --max-cycles=" << opts.max_cycles << '\n';
    top->final();
#if VM_TRACE
    if (tfp != nullptr) {
      tfp->close();
    }
#endif
    return 1;
  }

  top->final();
#if VM_TRACE
  if (tfp != nullptr) {
    tfp->close();
  }
#endif
  return 0;
}
