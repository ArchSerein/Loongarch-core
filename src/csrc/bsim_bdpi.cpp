#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cctype>
#include <fstream>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "bluesim_kernel_api.h"
#include "model_mkTbBDPI.h"

#include "../include/generated/autoconf.h"
#include "tb_memory.hpp"
#include "mmio.hpp"
#ifdef CONFIG_DIFFTEST
#include "difftest.hpp"
#endif

namespace {

struct Options {
  std::string mem_image = "build/mem.bin";
  std::uint32_t start_pc = 0x1c000000;
  bool enable_difftest = false;
#ifdef CONFIG_DIFFTEST
  std::string diff_ref_so;
#endif
};

struct LoadedImageSegment {
  std::uint32_t addr = 0;
  std::vector<std::uint8_t> bytes;
};

using LoadedImage = std::vector<LoadedImageSegment>;

static std::uint32_t g_exit_code = 1;
static bool g_finished = false;

static tSimStateHdl g_sim_hdl = nullptr;

#ifdef CONFIG_DIFFTEST
enum class CounterInstKind {
  None,
  TimeLow,
  CounterId,
  TimeHigh,
};

CounterInstKind decode_counter_inst(std::uint32_t inst) {
  const std::uint32_t op_31_26 = (inst >> 26) & 0x3f;
  const std::uint32_t op_25_22 = (inst >> 22) & 0xf;
  const std::uint32_t op_21_20 = (inst >> 20) & 0x3;
  const std::uint32_t op_19_15 = (inst >> 15) & 0x1f;
  const std::uint32_t rk = (inst >> 10) & 0x1f;
  const std::uint32_t rj = (inst >> 5) & 0x1f;
  const std::uint32_t rd = inst & 0x1f;

  if (op_31_26 != 0 || op_25_22 != 0 || op_21_20 != 0 || op_19_15 != 0) {
    return CounterInstKind::None;
  }

  if (rk == 0x18) {
    if (rd == 0 && rj != 0) {
      return CounterInstKind::CounterId;
    }
    if (rj == 0) {
      return CounterInstKind::TimeLow;
    }
  }

  if (rk == 0x19 && rj == 0) {
    return CounterInstKind::TimeHigh;
  }

  return CounterInstKind::None;
}
#endif

std::uint32_t parse_u32_env(const char* name, std::uint32_t fallback) {
  const char* value = std::getenv(name);
  if (value == nullptr || value[0] == '\0') {
    return fallback;
  }
  return static_cast<std::uint32_t>(std::strtoul(value, nullptr, 0));
}

std::string get_env_string(const char* name, const std::string& fallback = "") {
  const char* value = std::getenv(name);
  if (value == nullptr) {
    return fallback;
  }
  return value;
}

bool parse_bool_env(const char* name, bool fallback) {
  const char* value = std::getenv(name);
  if (value == nullptr || value[0] == '\0') {
    return fallback;
  }
  return std::strcmp(value, "0") != 0 &&
         std::strcmp(value, "false") != 0 &&
         std::strcmp(value, "False") != 0 &&
         std::strcmp(value, "no") != 0 &&
         std::strcmp(value, "off") != 0;
}

bool has_suffix(const std::string& s, const char* suffix) {
  const std::size_t suffix_len = std::strlen(suffix);
  return s.size() >= suffix_len &&
         s.compare(s.size() - suffix_len, suffix_len, suffix) == 0;
}

std::string trim(const std::string& s) {
  std::size_t first = 0;
  while (first < s.size() && std::isspace(static_cast<unsigned char>(s[first]))) {
    ++first;
  }
  std::size_t last = s.size();
  while (last > first && std::isspace(static_cast<unsigned char>(s[last - 1]))) {
    --last;
  }
  return s.substr(first, last - first);
}

bool parse_hex_u32(const std::string& text, std::uint32_t* value) {
  char* end = nullptr;
  unsigned long parsed = std::strtoul(text.c_str(), &end, 16);
  if (end == text.c_str()) {
    return false;
  }
  while (*end != '\0') {
    if (!std::isspace(static_cast<unsigned char>(*end))) {
      return false;
    }
    ++end;
  }
  if (parsed > 0xfffffffful) {
    return false;
  }
  *value = static_cast<std::uint32_t>(parsed);
  return true;
}

Options parse_env() {
  Options opts;
  opts.mem_image = get_env_string("BSIM_MEM_IMAGE", opts.mem_image);
  opts.start_pc = parse_u32_env("BSIM_START_PC", opts.start_pc);
#ifdef CONFIG_DIFFTEST
  opts.enable_difftest = parse_bool_env("BSIM_DIFFTEST", true);
  opts.diff_ref_so = get_env_string("BSIM_DIFF_REF_SO", get_env_string("DIFFTEST_REF_SO"));
#endif
  return opts;
}

LoadedImage load_verilog_mem_image(Memory& mem, const Options& opts) {
  LoadedImage segments;
  std::ifstream input(opts.mem_image);
  if (!input.is_open()) {
    std::cerr << "bsim: no memory image at " << opts.mem_image
              << ", starting from zeroed memory\n";
    return segments;
  }

  std::uint32_t addr = 0;
  LoadedImageSegment* current_segment = nullptr;
  std::size_t byte_count = 0;
  std::size_t section_count = 0;
  std::string line;
  std::size_t line_no = 0;

  while (std::getline(input, line)) {
    ++line_no;
    line = trim(line);
    if (line.empty()) {
      continue;
    }
    if (line[0] == '@') {
      std::uint32_t section_addr = 0;
      if (!parse_hex_u32(line.substr(1), &section_addr)) {
        std::cerr << "bsim: invalid address directive in " << opts.mem_image
                  << ':' << line_no << ": " << line << '\n';
        std::exit(EXIT_FAILURE);
      }
      addr = section_addr;
      segments.push_back(LoadedImageSegment{section_addr, {}});
      current_segment = &segments.back();
      ++section_count;
      continue;
    }
    if (current_segment == nullptr) {
      std::cerr << "bsim: data before first address directive in "
                << opts.mem_image << ':' << line_no << '\n';
      std::exit(EXIT_FAILURE);
    }

    std::uint32_t byte = 0;
    if (!parse_hex_u32(line, &byte) || byte > 0xffu) {
      std::cerr << "bsim: invalid byte in " << opts.mem_image
                << ':' << line_no << ": " << line << '\n';
      std::exit(EXIT_FAILURE);
    }

    const std::uint32_t shift = (addr & 0x3u) * 8u;
    mem.write(addr, byte << shift, static_cast<std::uint8_t>(1u << (addr & 0x3u)));
    current_segment->bytes.push_back(static_cast<std::uint8_t>(byte));
    ++byte_count;
    ++addr;
  }

  std::cout << "load " << opts.mem_image << " " << byte_count
            << " bytes in " << section_count << " sections\n";
  return segments;
}

LoadedImage load_mem_image(Memory& mem, const Options& opts) {
  if (has_suffix(opts.mem_image, ".vlog") || has_suffix(opts.mem_image, ".mem")) {
    return load_verilog_mem_image(mem, opts);
  }

  LoadedImage segments;
  std::ifstream input(opts.mem_image, std::ios::binary | std::ios::ate);
  if (!input.is_open()) {
    std::cerr << "bsim: no memory image at " << opts.mem_image
              << ", starting from zeroed memory\n";
    return segments;
  }

  const std::streamsize file_size = input.tellg();
  input.seekg(0, std::ios::beg);

  if (file_size <= 0) {
    std::cout << "load " << opts.mem_image << " 0 bytes\n";
    return segments;
  }

  const std::size_t word_count = (file_size + 3) / 4;
  if (word_count > mem.get_words_size()) {
    std::cerr << "bsim: memory image too large (" << file_size << " bytes)\n";
    std::exit(EXIT_FAILURE);
  }

  std::vector<std::uint8_t> buffer(word_count * 4, 0);
  input.read(reinterpret_cast<char*>(buffer.data()), file_size);
  mem.init(buffer);
  LoadedImageSegment segment;
  segment.addr = opts.start_pc;
  segment.bytes.assign(mem.raw_data(), mem.raw_data() + mem.raw_size());
  segments.push_back(std::move(segment));

  std::cout << "load " << opts.mem_image << " " << file_size << " bytes ("
            << word_count << " words)\n";
  return segments;
}

class BdpiSim {
public:
  BdpiSim() : opts(parse_env()), mem(mmio) {
    mem.set_base_addr(opts.start_pc);
    image_segments = load_mem_image(mem, opts);

#ifdef CONFIG_DIFFTEST
    if (opts.enable_difftest) {
      difftest.reset(new Difftest(0, opts.diff_ref_so, opts.start_pc));
      if (!difftest->enabled()) {
        std::cerr << "bsim: difftest requested but failed to initialize reference model\n";
        std::exit(EXIT_FAILURE);
      }
      for (const LoadedImageSegment& segment : image_segments) {
        if (!segment.bytes.empty()) {
          difftest->load_memory_image(segment.bytes.data(), segment.bytes.size(), segment.addr);
        }
      }
    }
#endif

    std::cout << "Start BSC BDPI simulation\n";
    std::cerr << "bsim: core starts from reset pc 0x" << std::hex
              << opts.start_pc << std::dec << '\n';
    std::cout.flush();
    std::cerr.flush();
  }

  std::uint32_t start_pc() const {
    return opts.start_pc;
  }

  std::uint32_t read_mem(std::uint32_t addr) {
    check_memory_bound(addr, false);
    return mem.read(addr);
  }

  void write_mem(std::uint32_t addr, std::uint32_t data, std::uint8_t mask) {
    check_memory_bound(addr, true);
    mem.write(addr, data, mask);
  }

#ifdef CONFIG_DIFFTEST
  Difftest* difftest_ptr() {
    return difftest.get();
  }
#endif

private:
  Options opts;
  MMIOMap mmio;
  Memory mem;
  LoadedImage image_segments;
#ifdef CONFIG_DIFFTEST
  std::unique_ptr<Difftest> difftest;
#endif

  void check_memory_bound(std::uint32_t addr, bool is_write) {
    if (mem.isDeviceAddress(addr)) {
      return;
    } else if ((addr >> 24) == 0x1c) {
      return;
    } else if ((addr >> 24) == 0x00 || (addr >> 24) == 0x80 || (addr >> 24) == 0xa0) {
      return;
    }

    std::fprintf(stderr, "%s is out of bound at addr 0x%08x\n",
                 is_write ? "write" : "read", addr);
#ifdef CONFIG_DIFFTEST
    if (difftest != nullptr) {
      difftest->display();
    }
#endif
    g_exit_code = 1;
    std::exit(g_exit_code);
  }
};

BdpiSim& sim() {
  static BdpiSim instance;
  return instance;
}

void finish_with_code(std::uint32_t code) {
  g_exit_code = code;
  g_finished = true;
  if (g_exit_code == 0) {
    std::cerr << "\nbsim: PASSED\n";
  } else {
    std::cerr << "\nbsim: FAILED (code=" << g_exit_code << ")\n";
  }
  std::cerr.flush();
  std::cout.flush();
  if (g_sim_hdl != nullptr) {
    bk_finish_now(g_sim_hdl, static_cast<tSInt32>(g_exit_code));
    return;
  }
  std::exit(static_cast<int>(g_exit_code));
}

void set_env_option(const char* name, const char* value) {
  if (value == nullptr) {
    return;
  }
  setenv(name, value, 1);
}

void configure_from_args(int argc, char** argv) {
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], "--mem-image") == 0 && i + 1 < argc) {
      set_env_option("BSIM_MEM_IMAGE", argv[++i]);
    } else if (std::strcmp(argv[i], "--start-pc") == 0 && i + 1 < argc) {
      set_env_option("BSIM_START_PC", argv[++i]);
#ifdef CONFIG_DIFFTEST
    } else if (std::strcmp(argv[i], "--difftest") == 0) {
      set_env_option("BSIM_DIFFTEST", "1");
    } else if (std::strcmp(argv[i], "--diff-ref-so") == 0 && i + 1 < argc) {
      set_env_option("BSIM_DIFF_REF_SO", argv[i + 1]);
      set_env_option("DIFFTEST_REF_SO", argv[i + 1]);
      ++i;
#endif
    } else if (std::strcmp(argv[i], "--") == 0) {
      break;
    }
  }
}

#ifdef CONFIG_DIFFTEST
Difftest* active_difftest() {
  Difftest* difftest = sim().difftest_ptr();
  if (difftest == nullptr || !difftest->enabled()) {
    return nullptr;
  }
  return difftest;
}

std::uint64_t diff_main_time = 0;
std::uint64_t last_timer_64_value = 0;
bool g_difftest_trigger = false;

void trigger_difftest() {
  g_difftest_trigger = true;
}

void run_pending_difftest() {
  if (!g_difftest_trigger) {
    return;
  }
  g_difftest_trigger = false;

  Difftest* difftest = active_difftest();
  if (difftest == nullptr) {
    return;
  }

  const int state = difftest->step(diff_main_time);
  ++diff_main_time;
  if (state == STATE_ABORT) {
    std::cerr << "\nbsim: DIFFTEST MISMATCH\n";
    difftest->display();
    finish_with_code(3);
  }
}
#endif

}  // namespace

extern "C" unsigned int bdpi_get_start_pc() {
  return sim().start_pc();
}

extern "C" unsigned int bdpi_mem_read(unsigned int addr) {
  return sim().read_mem(addr);
}

extern "C" void bdpi_mem_write(unsigned int addr, unsigned int data, unsigned char mask) {
  sim().write_mem(addr, data, mask);
}

extern "C" void bdpi_halt(unsigned int code) {
  finish_with_code(code);
}

#ifdef CONFIG_DIFFTEST
extern "C" void bdpi_difftest_greg_state(
    unsigned int gpr_0, unsigned int gpr_1, unsigned int gpr_2, unsigned int gpr_3,
    unsigned int gpr_4, unsigned int gpr_5, unsigned int gpr_6, unsigned int gpr_7,
    unsigned int gpr_8, unsigned int gpr_9, unsigned int gpr_10, unsigned int gpr_11,
    unsigned int gpr_12, unsigned int gpr_13, unsigned int gpr_14, unsigned int gpr_15,
    unsigned int gpr_16, unsigned int gpr_17, unsigned int gpr_18, unsigned int gpr_19,
    unsigned int gpr_20, unsigned int gpr_21, unsigned int gpr_22, unsigned int gpr_23,
    unsigned int gpr_24, unsigned int gpr_25, unsigned int gpr_26, unsigned int gpr_27,
    unsigned int gpr_28, unsigned int gpr_29, unsigned int gpr_30, unsigned int gpr_31) {
  Difftest* difftest = active_difftest();
  if (difftest == nullptr) {
    return;
  }

  arch_greg_state_t* regs = difftest->get_greg_state();
  regs->gpr[0] = gpr_0;
  regs->gpr[1] = gpr_1;
  regs->gpr[2] = gpr_2;
  regs->gpr[3] = gpr_3;
  regs->gpr[4] = gpr_4;
  regs->gpr[5] = gpr_5;
  regs->gpr[6] = gpr_6;
  regs->gpr[7] = gpr_7;
  regs->gpr[8] = gpr_8;
  regs->gpr[9] = gpr_9;
  regs->gpr[10] = gpr_10;
  regs->gpr[11] = gpr_11;
  regs->gpr[12] = gpr_12;
  regs->gpr[13] = gpr_13;
  regs->gpr[14] = gpr_14;
  regs->gpr[15] = gpr_15;
  regs->gpr[16] = gpr_16;
  regs->gpr[17] = gpr_17;
  regs->gpr[18] = gpr_18;
  regs->gpr[19] = gpr_19;
  regs->gpr[20] = gpr_20;
  regs->gpr[21] = gpr_21;
  regs->gpr[22] = gpr_22;
  regs->gpr[23] = gpr_23;
  regs->gpr[24] = gpr_24;
  regs->gpr[25] = gpr_25;
  regs->gpr[26] = gpr_26;
  regs->gpr[27] = gpr_27;
  regs->gpr[28] = gpr_28;
  regs->gpr[29] = gpr_29;
  regs->gpr[30] = gpr_30;
  regs->gpr[31] = gpr_31;
}

extern "C" void bdpi_difftest_csr_state(
    unsigned int crmd, unsigned int prmd, unsigned int euen, unsigned int ecfg,
    unsigned int estat, unsigned int era, unsigned int badv, unsigned int eentry,
    unsigned int tlbidx, unsigned int tlbehi, unsigned int tlbelo0, unsigned int tlbelo1,
    unsigned int asid, unsigned int pgdl, unsigned int pgdh,
    unsigned int save0, unsigned int save1, unsigned int save2, unsigned int save3,
    unsigned int tid, unsigned int tcfg, unsigned int tval, unsigned int llbctl,
    unsigned int tlbrentry, unsigned int dmw0, unsigned int dmw1) {
  Difftest* difftest = active_difftest();
  if (difftest == nullptr) {
    return;
  }

  arch_csr_state_t* csr = difftest->get_csr_state();
  csr->crmd = crmd;
  csr->prmd = prmd;
  csr->euen = euen;
  csr->ecfg = ecfg;
  csr->estat = estat;
  csr->era = era;
  csr->badv = badv;
  csr->eentry = eentry;
  csr->tlbidx = tlbidx;
  csr->tlbehi = tlbehi;
  csr->tlbelo0 = tlbelo0;
  csr->tlbelo1 = tlbelo1;
  csr->asid = asid;
  csr->pgdl = pgdl;
  csr->pgdh = pgdh;
  csr->save0 = save0;
  csr->save1 = save1;
  csr->save2 = save2;
  csr->save3 = save3;
  csr->tid = tid;
  csr->tcfg = tcfg;
  csr->tval = tval;
  csr->llbctl = llbctl;
  csr->tlbrentry = tlbrentry;
  csr->dmw0 = dmw0;
  csr->dmw1 = dmw1;
}

extern "C" void bdpi_difftest_excp_event(unsigned char excp_valid, unsigned char eret,
                                         unsigned int intrNo, unsigned int cause,
                                         unsigned int exceptionPC,
                                         unsigned int exceptionInst) {
  Difftest* difftest = active_difftest();
  if (difftest == nullptr) {
    return;
  }

  excp_event_t* excp = difftest->get_excp_event();
  excp->excp_valid = excp_valid;
  excp->eret = eret;
  excp->interrupt = intrNo;
  excp->exception = cause;
  excp->exceptionPC = exceptionPC;
  excp->exceptionIst = exceptionInst;
  if (excp_valid != 0) {
    trigger_difftest();
  }
}

extern "C" void bdpi_difftest_store_event(unsigned char valid,
                                          unsigned long long storePAddr,
                                          unsigned long long storeVAddr,
                                          unsigned long long storeData) {
  Difftest* difftest = active_difftest();
  if (difftest == nullptr) {
    return;
  }

  store_event_t* store = difftest->get_store_event(0);
  store->valid = valid;
  store->paddr = storePAddr;
  store->vaddr = storeVAddr;
  store->data = storeData;
}

extern "C" void bdpi_difftest_load_event(unsigned char valid,
                                         unsigned long long paddr,
                                         unsigned long long vaddr) {
  Difftest* difftest = active_difftest();
  if (difftest == nullptr) {
    return;
  }

  load_event_t* load = difftest->get_load_event(0);
  load->valid = valid;
  load->paddr = paddr;
  load->vaddr = vaddr;
}

extern "C" void bdpi_difftest_instr_commit(unsigned char valid, unsigned int pc,
                                           unsigned int next_pc, unsigned int inst,
                                           unsigned char wen, unsigned char wdest,
                                           unsigned int wdata, unsigned char skip,
                                           unsigned char is_tlbfill,
                                           unsigned char tlbfill_index) {
  Difftest* difftest = active_difftest();
  if (difftest == nullptr) {
    return;
  }
  (void)skip;

  std::fprintf(stderr,
               "[BDPIDIFF] commit valid=%u pc=0x%08x inst=0x%08x wen=%u wdest=%u wdata=0x%08x\n",
               valid, pc, inst, wen, wdest, wdata);

  instr_commit_t* commit = difftest->get_instr_commit(0);
  commit->valid = valid;
  commit->pc = pc;
  commit->next_pc = next_pc;
  commit->inst = inst;
  commit->skip = 0;
  commit->wen = (wen != 0) ? 1 : 0;
  commit->wdest = wdest;
  commit->wdata = wdata;
  commit->is_TLBFILL = (is_tlbfill != 0) ? 1 : 0;
  commit->TLBFILL_index = tlbfill_index;
  commit->is_CNTinst = 0;
  commit->timer_64_value = last_timer_64_value;

  switch (decode_counter_inst(inst)) {
    case CounterInstKind::TimeLow:
      last_timer_64_value =
          (last_timer_64_value & 0xffffffff00000000ULL) | static_cast<std::uint64_t>(wdata);
      commit->is_CNTinst = 1;
      commit->timer_64_value = last_timer_64_value;
      break;
    case CounterInstKind::CounterId:
      commit->is_CNTinst = 1;
      commit->timer_64_value = last_timer_64_value;
      break;
    case CounterInstKind::TimeHigh:
      last_timer_64_value =
          (static_cast<std::uint64_t>(wdata) << 32) | (last_timer_64_value & 0xffffffffULL);
      commit->is_CNTinst = 1;
      commit->timer_64_value = last_timer_64_value;
      break;
    case CounterInstKind::None:
      break;
  }
  if (valid != 0) {
    trigger_difftest();
  }
}
#endif

#ifdef CONFIG_TRACE_PERFORMANCE
uint64_t inst_cnt;
uint64_t cycle_cnt;
extern "C" void inst_count() {
  ++inst_cnt;
}
extern "C" void cycle_count() {
  ++cycle_cnt;
}
#endif

int main(int argc, char** argv) {
  configure_from_args(argc, argv);

  Model* model = static_cast<Model*>(new_MODEL_mkTbBDPI());
  g_sim_hdl = bk_init(static_cast<tModel>(model), 1);
  if (g_sim_hdl == nullptr) {
    std::cerr << "bsim: failed to initialize Bluesim kernel\n";
    delete model;
    return 1;
  }

  for (int i = 1; i < argc; ++i) {
    bk_append_argument(g_sim_hdl, argv[i]);
  }

  bk_use_default_reset(g_sim_hdl);
  while (!g_finished && !bk_finished(g_sim_hdl) && !bk_aborted(g_sim_hdl)) {
    if (bk_advance(g_sim_hdl, 0) == BK_ERROR) {
      std::cerr << "bsim: Bluesim advance failed\n";
      g_exit_code = 1;
      break;
    }
#ifdef CONFIG_DIFFTEST
    run_pending_difftest();
#endif
  }

  if (!g_finished && (bk_finished(g_sim_hdl) || bk_aborted(g_sim_hdl))) {
    g_exit_code = static_cast<std::uint32_t>(bk_exit_status(g_sim_hdl));
  }

  #ifdef CONFIG_TRACE_PERFORMANCE
  double ipc = static_cast<double>(inst_cnt) / static_cast<double>(cycle_cnt);
  printf("Cycles: 0x%lx\nInsts: 0x%lx\nIPC: %f\n", cycle_cnt, inst_cnt, ipc);
  #endif

  bk_shutdown(g_sim_hdl);
  g_sim_hdl = nullptr;
  delete model;
  return static_cast<int>(g_exit_code);
}
