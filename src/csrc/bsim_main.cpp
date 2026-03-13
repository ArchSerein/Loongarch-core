#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

#include <unistd.h>

#include "tb_memory.hpp"
#include "mmio.hpp"
#include "difftest.hpp"
#include "SimIndication.h"
#include "SimRequest.h"
#include "../include/generated/autoconf.h"

namespace {

struct Options {
  std::string mem_image = "build/mem.bin";
  std::uint32_t start_pc = 0;
  bool enable_difftest = false;
  std::string diff_ref_so;
};

static std::unique_ptr<SimRequestProxy> g_request = nullptr;
static volatile int g_run = 1;
static std::uint32_t g_exit_code = 1;

Options parse_args(int argc, char** argv) {
  Options opts;
#ifdef CONFIG_DIFFTEST
  opts.enable_difftest = true;
#endif

  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--mem-image") == 0 && (i + 1) < argc) {
      opts.mem_image = argv[++i];
      continue;
    }
    if (std::strcmp(argv[i], "--start-pc") == 0 && (i + 1) < argc) {
      opts.start_pc = static_cast<std::uint32_t>(std::strtoul(argv[++i], nullptr, 0));
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

void load_mem_image(Memory& mem, const struct Options& opts) {
  std::ifstream input(opts.mem_image, std::ios::binary | std::ios::ate);
  if (!input.is_open()) {
      std::cerr << "bsim: no memory image at " << opts.mem_image
                << ", starting from zeroed memory\n";
      return;
  }

  const std::streamsize file_size = input.tellg();
  input.seekg(0, std::ios::beg);

  if (file_size <= 0) {
      std::cout << "load " << opts.mem_image << " 0 bytes\n";
      return;
  }

  const std::size_t word_count = (file_size + 3) / 4;
  if (word_count > mem.get_words_size()) {
      std::cerr << "bsim: memory image too large (" << file_size << " bytes)\n";
      std::exit(EXIT_FAILURE);
  }

  std::vector<std::uint8_t> buffer(word_count * 4, 0);
  input.read(reinterpret_cast<char*>(buffer.data()), file_size);

  mem.init(buffer);

  std::cout << "load " << opts.mem_image << " " << file_size << " bytes (" 
            << word_count << " words)\n";
}

class MySimIndicationCb final : public SimIndicationWrapper {
public:
  MySimIndicationCb(unsigned int id, Memory& mem_ref, std::uint32_t start_pc, Difftest* difftest_ref)
      : SimIndicationWrapper(id), mem(mem_ref), difftest(difftest_ref) {
        mem.set_base_addr(start_pc);
  }

  void halt(std::uint32_t code) override {
    g_exit_code = code;
    g_run = 0;
  }

  void putc(std::uint8_t c) override {
    std::cout << static_cast<char>(c) << std::flush;
  }

  void read_mem_req(std::uint32_t addr) override {
    check_memory_bound(addr, false);
    if (!g_run) {
      return;
    }
    g_request->read_mem_resp(mem.read(addr));
  }

  void write_mem_req(std::uint32_t addr, std::uint32_t data, std::uint8_t mask) override {
    check_memory_bound(addr, true);
    if (!g_run) {
      return;
    }
    mem.write(addr, data, mask);
  }

  void difftest_instr_commit(std::uint32_t pc, std::uint32_t inst, std::uint8_t wen,
                             std::uint8_t wdest, std::uint32_t wdata) override {
    if (!g_run || difftest == nullptr || !difftest->enabled()) {
      return;
    }

    instr_commit_t* commit = difftest->get_instr_commit(0);
    commit->valid = 1;
    commit->pc = pc;
    commit->inst = inst;
    commit->skip = is_skip_difftest;
    commit->wen = (wen != 0) ? 1 : 0;
    commit->wdest = wdest;
    commit->wdata = wdata;

    const int state = difftest->step(diff_main_time);
    ++diff_main_time;
    if (state == STATE_ABORT) {
      std::cerr << "\nbsim: DIFFTEST MISMATCH\n";
      difftest->display();
      g_exit_code = 3;
      g_run = 0;
    }
    is_skip_difftest = false;
  }

private:
  Memory& mem;
  Difftest* difftest = nullptr;
  std::uint64_t diff_main_time = 0;
  std::uint8_t  is_skip_difftest = false;
  void check_memory_bound(std::uint32_t addr, bool is_write) {
    if ((addr >> 16) == 0xbfaf) {
      auto ret = mem.isDeviceAddress(addr & 0xffff);
      if (!ret) goto bad;
      else is_skip_difftest = 1;
    } else if ((addr >> 24) != 0x1c)
      goto bad;
    return;
  bad:
    fprintf(stderr, "%s is out of bound at addr 0x%08x\n", is_write ? "write" : "read", addr);
    difftest->display();
    halt(1);
  }
};

}  // namespace

int main(int argc, char** argv) {
  const Options opts = parse_args(argc, argv);

  MMIOMap mmio;
  Memory mem(mmio);
  load_mem_image(mem, opts);

  std::unique_ptr<Difftest> difftest;
  if (opts.enable_difftest) {
    difftest.reset(new Difftest(0, opts.diff_ref_so, opts.start_pc));
    if (!difftest->enabled()) {
      std::cerr << "bsim: difftest requested but failed to initialize reference model\n";
      return 1;
    }
    difftest->load_memory_image(mem.raw_data(), mem.raw_size(), opts.start_pc);
  }

  std::cout << "Start BSC Connectal simulation\n";
  std::cout.flush();

  g_request = std::make_unique<SimRequestProxy>(IfcNames_SimRequestS2H);
  auto indication =
      std::make_unique<MySimIndicationCb>(IfcNames_SimIndicationH2S, mem, opts.start_pc, difftest.get());
  (void)indication;

  g_request->hostToCpu(opts.start_pc);

  while (g_run != 0) {
    usleep(1000);
  }

  if (g_exit_code == 0) {
    std::cerr << "\nbsim: PASSED\n";
  } else {
    std::cerr << "\nbsim: FAILED (code=" << g_exit_code << ")\n";
  }

  return static_cast<int>(g_exit_code);
}
