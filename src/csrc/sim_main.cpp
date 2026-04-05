#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <deque>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <verilated.h>
#include "VmkTb.h"

#if VM_TRACE
#include <verilated_vcd_c.h>
#endif

namespace {

constexpr std::uint32_t kTbWordAddrWidth = 20;

struct TbMemory {
  TbMemory() : words(std::size_t{1} << kTbWordAddrWidth, 0) {}
  std::vector<std::uint32_t> words;
};

struct Options {
  std::uint64_t max_cycles = 1000000;
  bool trace = false;
  std::string trace_path = "build/wave.vcd";
  std::string mem_image = "build/mem.bin";
  std::uint32_t start_pc = 0;
  std::string diff_ref_so;
};

void load_mem_image(TbMemory& mem, const std::string& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input.is_open()) {
    std::cerr << "sim: no memory image at " << path
              << ", starting from zeroed memory\n";
    return;
  }

  input.seekg(0, std::ios::end);
  const std::size_t file_size = static_cast<std::size_t>(input.tellg());
  input.seekg(0, std::ios::beg);

  const std::size_t word_count = (file_size + 3) / 4;
  if (word_count > mem.words.size()) {
    std::cerr << "sim: memory image too large (" << file_size << " bytes)\n";
    std::exit(1);
  }

  for (std::size_t i = 0; i < word_count; ++i) {
    std::uint8_t bytes[4] = {0, 0, 0, 0};
    input.read(reinterpret_cast<char*>(bytes), 4);
    mem.words[i] = static_cast<std::uint32_t>(bytes[0]) |
                   (static_cast<std::uint32_t>(bytes[1]) << 8) |
                   (static_cast<std::uint32_t>(bytes[2]) << 16) |
                   (static_cast<std::uint32_t>(bytes[3]) << 24);
  }
}

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
    if (std::strcmp(argv[i], "--start-pc") == 0 && (i + 1) < argc) {
      opts.start_pc = static_cast<std::uint32_t>(std::strtoul(argv[++i], nullptr, 0));
      continue;
    }
    if (std::strcmp(argv[i], "--mem-image") == 0 && (i + 1) < argc) {
      opts.mem_image = argv[++i];
      continue;
    }
    if (std::strcmp(argv[i], "--diff-ref-so") == 0 && (i + 1) < argc) {
      opts.diff_ref_so = argv[++i];
      continue;
    }
    std::cerr << "unknown argument: " << argv[i] << '\n';
    std::exit(2);
  }
  return opts;
}

struct StepInputs {
  bool en_request_host_to_cpu = false;
  std::uint32_t request_host_to_cpu_startpc = 0;
  bool en_request_read_mem_resp = false;
  std::uint32_t request_read_mem_resp_data = 0;

  bool en_indication_halt = false;
  bool en_indication_read_mem_req = false;
  bool en_indication_write_mem_req = false;
};

void drive_inputs(VmkTb& top, const StepInputs& in) {
  top.EN_request_hostToCpu = static_cast<std::uint8_t>(in.en_request_host_to_cpu);
  top.request_hostToCpu_startpc = in.request_host_to_cpu_startpc;
  top.EN_request_read_mem_resp = static_cast<std::uint8_t>(in.en_request_read_mem_resp);
  top.request_read_mem_resp_data = in.request_read_mem_resp_data;

  top.EN_indication_halt = static_cast<std::uint8_t>(in.en_indication_halt);
  top.EN_indication_read_mem_req = static_cast<std::uint8_t>(in.en_indication_read_mem_req);
  top.EN_indication_write_mem_req = static_cast<std::uint8_t>(in.en_indication_write_mem_req);
}

void eval_half_cycle(VmkTb& top, vluint64_t& main_time,
                     const StepInputs& in,
                     std::uint8_t clk
#if VM_TRACE
                     , VerilatedVcdC* tfp
#endif
) {
  top.CLK = clk;
  drive_inputs(top, in);
  top.eval();
#if VM_TRACE
  if (tfp != nullptr) {
    tfp->dump(main_time);
  }
#endif
  ++main_time;
}

void check_word_addr(std::uint32_t addr, std::size_t mem_words, const char* op) {
  if (addr >= mem_words) {
    std::cerr << "sim: " << op << " out of range at word address 0x"
              << std::hex << addr << std::dec << '\n';
    std::exit(1);
  }
}

}  // namespace

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  const Options opts = parse_args(argc, argv);

  TbMemory mem;
  load_mem_image(mem, opts.mem_image);

  auto top = std::unique_ptr<VmkTb>(new VmkTb());
  vluint64_t main_time = 0;

#if VM_TRACE
  std::unique_ptr<VerilatedVcdC> tfp;
  if (opts.trace) {
    Verilated::traceEverOn(true);
    tfp = std::unique_ptr<VerilatedVcdC>(new VerilatedVcdC());
    top->trace(tfp.get(), 99);
    tfp->open(opts.trace_path.c_str());
  }
#endif

  StepInputs idle;

  top->RST_N = 0;
  eval_half_cycle(*top, main_time, idle, 0
#if VM_TRACE
                  , tfp.get()
#endif
  );
  eval_half_cycle(*top, main_time, idle, 1
#if VM_TRACE
                  , tfp.get()
#endif
  );
  eval_half_cycle(*top, main_time, idle, 0
#if VM_TRACE
                  , tfp.get()
#endif
  );
  eval_half_cycle(*top, main_time, idle, 1
#if VM_TRACE
                  , tfp.get()
#endif
  );
  top->RST_N = 1;

  std::deque<std::uint32_t> pending_read_resps;
  std::uint64_t cycles = 0;
  bool started = false;
  bool halted = false;
  std::uint32_t exit_code = 1;

  while (!Verilated::gotFinish() && !halted && cycles < opts.max_cycles) {
    StepInputs in;

    // Evaluate combinationally first to observe ready/data signals.
    eval_half_cycle(*top, main_time, in, 0
#if VM_TRACE
                    , tfp.get()
#endif
    );

    if (!started && top->RDY_request_hostToCpu) {
      in.en_request_host_to_cpu = true;
      in.request_host_to_cpu_startpc = opts.start_pc;
      started = true;
    }

    if (top->RDY_indication_read_mem_req) {
      in.en_indication_read_mem_req = true;
      const std::uint32_t word_addr = top->indication_read_mem_req;
      check_word_addr(word_addr, mem.words.size(), "read");
      pending_read_resps.push_back(mem.words[word_addr]);
    }

    if (top->RDY_indication_write_mem_req) {
      in.en_indication_write_mem_req = true;
      const std::uint64_t raw = (static_cast<std::uint64_t>(top->indication_write_mem_req[1]) << 32) | static_cast<std::uint64_t>(top->indication_write_mem_req[0]);

      // Preferred packing: {addr, data}. Fallback to {data, addr} if needed.
      std::uint32_t addr = static_cast<std::uint32_t>(raw >> 32);
      std::uint32_t data = static_cast<std::uint32_t>(raw & 0xffffffffu);
      if (addr >= mem.words.size()) {
        const std::uint32_t alt_addr = static_cast<std::uint32_t>(raw & 0xffffffffu);
        const std::uint32_t alt_data = static_cast<std::uint32_t>(raw >> 32);
        if (alt_addr < mem.words.size()) {
          addr = alt_addr;
          data = alt_data;
        }
      }

      check_word_addr(addr, mem.words.size(), "write");
      mem.words[addr] = data;
    }

    if (!pending_read_resps.empty() && top->RDY_request_read_mem_resp) {
      in.en_request_read_mem_resp = true;
      in.request_read_mem_resp_data = pending_read_resps.front();
      pending_read_resps.pop_front();
    }

    if (top->RDY_indication_halt) {
      in.en_indication_halt = true;
      exit_code = top->indication_halt;
      halted = true;
    }

    eval_half_cycle(*top, main_time, in, 1
#if VM_TRACE
                    , tfp.get()
#endif
    );

    ++cycles;
  }

  top->final();

#if VM_TRACE
  if (tfp != nullptr) {
    tfp->close();
  }
#endif

  if (halted) {
    std::cerr << "\nsim: halt received after " << cycles
              << " cycles (code=" << exit_code << ")\n";
    return static_cast<int>(exit_code);
  }

  if (Verilated::gotFinish()) {
    return 0;
  }

  std::cerr << "simulation stopped after reaching --max-cycles="
            << opts.max_cycles << '\n';
  return 1;
}
