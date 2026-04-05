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

#include "../include/generated/autoconf.h"
#include "tb_memory.hpp"
#include "mmio.hpp"
#ifdef CONFIG_DIFFTEST
#include "difftest.hpp"
#endif
#include "SimIndication.h"
#include "SimRequest.h"

namespace {

struct Options {
  std::string mem_image = "build/mem.bin";
  std::uint32_t start_pc = 0;
  bool enable_difftest = false;
#ifdef CONFIG_DIFFTEST
  std::string diff_ref_so;
#endif
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
#ifdef CONFIG_DIFFTEST
      opts.diff_ref_so = argv[++i];
#else
      ++i;
#endif
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
  MySimIndicationCb(unsigned int id, Memory& mem_ref, std::uint32_t start_pc
#ifdef CONFIG_DIFFTEST
                    , Difftest* difftest_ref
#endif
                    )
      : SimIndicationWrapper(id), mem(mem_ref)
#ifdef CONFIG_DIFFTEST
      , difftest(difftest_ref)
#endif
  {
        mem.set_base_addr(start_pc);
  }

  void halt(std::uint32_t code) override {
    g_exit_code = code;
    g_run = 0;
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

#ifdef CONFIG_DIFFTEST
  void difftest_greg_state(
      std::uint32_t gpr_0, std::uint32_t gpr_1, std::uint32_t gpr_2, std::uint32_t gpr_3,
      std::uint32_t gpr_4, std::uint32_t gpr_5, std::uint32_t gpr_6, std::uint32_t gpr_7,
      std::uint32_t gpr_8, std::uint32_t gpr_9, std::uint32_t gpr_10, std::uint32_t gpr_11,
      std::uint32_t gpr_12, std::uint32_t gpr_13, std::uint32_t gpr_14, std::uint32_t gpr_15,
      std::uint32_t gpr_16, std::uint32_t gpr_17, std::uint32_t gpr_18, std::uint32_t gpr_19,
      std::uint32_t gpr_20, std::uint32_t gpr_21, std::uint32_t gpr_22, std::uint32_t gpr_23,
      std::uint32_t gpr_24, std::uint32_t gpr_25, std::uint32_t gpr_26, std::uint32_t gpr_27,
      std::uint32_t gpr_28, std::uint32_t gpr_29, std::uint32_t gpr_30, std::uint32_t gpr_31) override {
    if (!g_run || difftest == nullptr || !difftest->enabled()) {
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

  void difftest_csr_state(std::uint32_t crmd, std::uint32_t prmd, std::uint32_t euen,
                          std::uint32_t ecfg, std::uint32_t estat, std::uint32_t era,
                          std::uint32_t badv, std::uint32_t eentry, std::uint32_t tlbidx,
                          std::uint32_t tlbehi, std::uint32_t tlbelo0, std::uint32_t tlbelo1,
                          std::uint32_t asid, std::uint32_t pgdl, std::uint32_t pgdh,
                          std::uint32_t save0, std::uint32_t save1, std::uint32_t save2,
                          std::uint32_t save3, std::uint32_t tid, std::uint32_t tcfg,
                          std::uint32_t tval, std::uint32_t llbctl, std::uint32_t tlbrentry,
                          std::uint32_t dmw0, std::uint32_t dmw1) override {
    if (!g_run || difftest == nullptr || !difftest->enabled()) {
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

  void difftest_excp_event(std::uint8_t excp_valid, std::uint8_t eret, std::uint32_t intrNo,
                           std::uint32_t cause, std::uint32_t exceptionPC,
                           std::uint32_t exceptionInst) override {
    if (!g_run || difftest == nullptr || !difftest->enabled()) {
      return;
    }

    excp_event_t* excp = difftest->get_excp_event();
    excp->excp_valid = excp_valid;
    excp->eret = eret;
    excp->interrupt = intrNo;
    excp->exception = cause;
    excp->exceptionPC = exceptionPC;
    excp->exceptionIst = exceptionInst;
  }

  void difftest_store_event(std::uint8_t valid, std::uint64_t storePAddr, std::uint64_t storeVAddr,
                            std::uint64_t storeData) override {
    if (!g_run || difftest == nullptr || !difftest->enabled()) {
      return;
    }

    store_event_t* store = difftest->get_store_event(0);
    store->valid = valid;
    store->paddr = storePAddr;
    store->vaddr = storeVAddr;
    store->data = storeData;
  }

  void difftest_load_event(std::uint8_t valid, std::uint64_t paddr, std::uint64_t vaddr) override {
    if (!g_run || difftest == nullptr || !difftest->enabled()) {
      return;
    }

    load_event_t* load = difftest->get_load_event(0);
    load->valid = valid;
    load->paddr = paddr;
    load->vaddr = vaddr;
  }

  void difftest_instr_commit(std::uint8_t valid, std::uint32_t pc, std::uint32_t next_pc, std::uint32_t inst,
                             std::uint8_t wen, std::uint8_t wdest, std::uint32_t wdata,
                             std::uint8_t skip) override {
    if (!g_run || difftest == nullptr || !difftest->enabled()) {
      return;
    }

    instr_commit_t* commit = difftest->get_instr_commit(0);
    commit->valid = valid;
    commit->pc = pc;
    commit->next_pc = next_pc;
    commit->inst = inst;
    commit->skip = skip;
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
  }
#endif

private:
  Memory& mem;
#ifdef CONFIG_DIFFTEST
  Difftest* difftest = nullptr;
  std::uint64_t diff_main_time = 0;
#endif

  void check_memory_bound(std::uint32_t addr, bool is_write) {
    if ((addr >> 16) == 0xbfaf) {
      auto ret = mem.isDeviceAddress(addr & 0xffff);
      if (!ret) goto bad;
      goto good;
    } else if ((addr >> 24) == 0x1c) {
      goto good;
    } else if ((addr >> 24) == 0x00) {
      goto good;
    } else goto bad;
  good:
    return;
  bad:
    fprintf(stderr, "%s is out of bound at addr 0x%08x\n", is_write ? "write" : "read", addr);
#ifdef CONFIG_DIFFTEST
    difftest->display();
#endif
    halt(1);
  }
};

}  // namespace

int main(int argc, char** argv) {
  const Options opts = parse_args(argc, argv);

  MMIOMap mmio;
  Memory mem(mmio);
  load_mem_image(mem, opts);

#ifdef CONFIG_DIFFTEST
  std::unique_ptr<Difftest> difftest;
  if (opts.enable_difftest) {
    difftest.reset(new Difftest(0, opts.diff_ref_so, opts.start_pc));
    if (!difftest->enabled()) {
      std::cerr << "bsim: difftest requested but failed to initialize reference model\n";
      return 1;
    }
    difftest->load_memory_image(mem.raw_data(), mem.raw_size(), opts.start_pc);
  }
#endif

  std::cout << "Start BSC Connectal simulation\n";
  std::cout.flush();

  g_request = std::make_unique<SimRequestProxy>(IfcNames_SimRequestS2H);
  auto indication =
      std::make_unique<MySimIndicationCb>(IfcNames_SimIndicationH2S, mem, opts.start_pc
#ifdef CONFIG_DIFFTEST
                                          , difftest.get()
#endif
      );
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

  std::_Exit(g_exit_code);
}
