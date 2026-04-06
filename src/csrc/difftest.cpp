#include "difftest.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <string>
#include <unistd.h>

namespace {

struct la32_timer {
    std::uint32_t counter_id = 0;
    std::uint32_t stable_counter_l = 0;
    std::uint32_t stable_counter_h = 0;
    std::uint32_t time_val = 0;
};

static const char* const kFallbackRefSoPath =
    "/root/Loongarch-core/chiplab/toolchains/nemu/la32r-nemu-interpreter-so";

static const int DIFFTEST_NR_GREG = sizeof(arch_greg_state_t) / sizeof(std::uint32_t);
static const int DIFFTEST_NR_CSRREG = sizeof(arch_csr_state_t) / sizeof(std::uint32_t);
static const int DIFFTEST_NR_REG = DIFFTEST_NR_GREG + DIFFTEST_NR_CSRREG;

static const char* const kRegName[DIFFTEST_NR_REG] = {
    "r0",      "ra",     "tp",      "sp",      "a0",      "a1",     "a2",        "a3",
    "a4",      "a5",     "a6",      "a7",      "t0",      "t1",     "t2",        "t3",
    "t4",      "t5",     "t6",      "t7",      "t8",      "x",      "fp",        "s0",
    "s1",      "s2",     "s3",      "s4",      "s5",      "s6",     "s7",        "s8",
    "crmd",    "prmd",   "euen",    "ecfg",    "era",     "badv",   "eentry",    "tlbidx",
    "tlbehi",  "tlbelo0","tlbelo1", "asid",    "pgdl",    "pgdh",   "save0",     "save1",
    "save2",   "save3",  "tid",     "tcfg",    "tval",    "llbctl", "tlbrentry", "dmw0",
    "dmw1",    "estat",  "this_pc"
};

static const char kCompareMask[DIFFTEST_NR_CSRREG] = {
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 0, 1
};

std::string resolve_ref_so_path(const std::string& cli_ref_so_path) {
    if (!cli_ref_so_path.empty()) {
        return cli_ref_so_path;
    }

    const char* env_ref_so = std::getenv("DIFFTEST_REF_SO");
    if (env_ref_so != nullptr && env_ref_so[0] != '\0') {
        return env_ref_so;
    }

    const char* user = std::getenv("USER");
    if (user != nullptr && user[0] != '\0') {
        std::string workspace_ref_so =
            std::string("/home/") + user +
            "/loong-arch/LoongArch/chiplab/toolchains/nemu/la32r-nemu-interpreter-so";
        if (access(workspace_ref_so.c_str(), F_OK) == 0) {
            return workspace_ref_so;
        }
    }

    return kFallbackRefSoPath;
}

}  // namespace

void* NemuProxy::load_symbol(const char* symbol_name, bool required) {
    dlerror();
    void* sym = dlsym(handle_, symbol_name);
    const char* err = dlerror();
    if (err != nullptr) {
        if (required) {
            std::fprintf(stderr, "difftest: missing symbol %s: %s\n", symbol_name, err);
        }
        return nullptr;
    }
    return sym;
}

NemuProxy::NemuProxy(int coreid, const std::string& ref_so_path) {
    (void)coreid;
    ref_so_path_ = resolve_ref_so_path(ref_so_path);

    if (access(ref_so_path_.c_str(), F_OK) != 0) {
        std::fprintf(
            stderr,
            "difftest: ref .so not found at %s (set DIFFTEST_REF_SO or --diff-ref-so)\n",
            ref_so_path_.c_str());
        return;
    }

    int flags = RTLD_LAZY;
#ifdef RTLD_DEEPBIND
    flags |= RTLD_DEEPBIND;
#endif
    handle_ = dlopen(ref_so_path_.c_str(), flags);
    if (handle_ == nullptr) {
        std::fprintf(stderr, "difftest: dlopen(%s) failed: %s\n", ref_so_path_.c_str(),
                     dlerror());
        return;
    }

    memcpy = reinterpret_cast<void (*)(std::uint64_t, void*, std::size_t, bool)>(
        load_symbol("difftest_memcpy"));
    regcpy = reinterpret_cast<void (*)(void*, bool, bool)>(load_symbol("difftest_regcpy"));
    csrcpy = reinterpret_cast<void (*)(void*, bool)>(load_symbol("difftest_csrcpy", false));
    uarchstatus_cpy = reinterpret_cast<void (*)(void*, bool)>(
        load_symbol("difftest_uarchstatus_cpy", false));
    store_commit = reinterpret_cast<int (*)(std::uint64_t, std::uint64_t)>(
        load_symbol("difftest_store_commit", false));
    exec = reinterpret_cast<void (*)(std::uint64_t)>(load_symbol("difftest_exec"));
    guided_exec = reinterpret_cast<std::uint64_t (*)(void*)>(
        load_symbol("difftest_guided_exec", false));
    raise_intr = reinterpret_cast<void (*)(std::uint64_t)>(
        load_symbol("difftest_raise_intr", false));
    isa_reg_display = reinterpret_cast<void (*)()>(load_symbol("isa_reg_display", false));
    tlbfill_index_set = reinterpret_cast<void (*)(std::uint32_t)>(
        load_symbol("difftest_tlbfill_index_set", false));
    timercpy = reinterpret_cast<void (*)(void*)>(load_symbol("difftest_timercpy", false));
    estat_sync = reinterpret_cast<void (*)(std::uint32_t, std::uint32_t)>(
        load_symbol("difftest_estat_sync", false));
    check_end = reinterpret_cast<int (*)()>(load_symbol("difftest_cosim_end", false));

    auto* nemu_init = reinterpret_cast<void (*)()>(load_symbol("difftest_init"));
    if (memcpy == nullptr || regcpy == nullptr || exec == nullptr || nemu_init == nullptr) {
        dlclose(handle_);
        handle_ = nullptr;
        return;
    }

    nemu_init();
    initialized_ = true;
    std::fprintf(stderr, "difftest: loaded ref from %s\n", ref_so_path_.c_str());
}

NemuProxy::~NemuProxy() {
    if (handle_ != nullptr) {
        dlclose(handle_);
        handle_ = nullptr;
    }
}

Difftest::Difftest(int coreid, const std::string& ref_so_path, std::uint32_t first_inst_pc)
    : coreid_(coreid), first_inst_pc_(first_inst_pc), dut(), ref() {
    state = std::make_unique<DiffState>();
    proxy = std::make_unique<DIFF_PROXY>(coreid, ref_so_path);
    if (!proxy->ready()) {
        proxy.reset();
    }
}

Difftest::~Difftest() {
}

void Difftest::load_memory_image(const void* image, std::size_t nbytes, std::uint32_t nemu_addr) {
    if (!enabled()) {
        return;
    }
    if (image == nullptr || nbytes == 0) {
        return;
    }
    proxy->memcpy(static_cast<std::uint64_t>(nemu_addr), const_cast<void*>(image), nbytes,
                  DIFFTEST_TO_REF);
    mem_synced_ = true;
}

void Difftest::do_first_instr_commit() {
    if (!enabled() || started_ || idx_commit_ == 0 || !dut.commit[0].valid) {
        return;
    }
    if (dut.commit[0].pc != first_inst_pc_) {
        return;
    }

    if (!mem_synced_) {
        std::fprintf(stderr,
                     "difftest: warning: first commit seen before reference memory sync\n");
    }

    proxy->regcpy(dut_regs_ptr_, DIFFTEST_TO_REF, DIFF_TO_REF_ALL);
    started_ = true;
    std::fprintf(stderr, "difftest: enabled at pc=0x%08x (core %d)\n", dut.commit[0].pc,
                 coreid_);
}

void Difftest::do_instr_commit(int index) {
    if (!enabled()) {
        return;
    }

    const instr_commit_t& commit = dut.commit[index];
    if (commit.is_TLBFILL && proxy->tlbfill_index_set != nullptr) {
        proxy->tlbfill_index_set(commit.TLBFILL_index);
    }
    if (commit.is_CNTinst && proxy->timercpy != nullptr) {
        la32_timer timer;
        timer.counter_id = dut.csr.tid;
        timer.stable_counter_l = static_cast<std::uint32_t>(commit.timer_64_value);
        timer.stable_counter_h = static_cast<std::uint32_t>(commit.timer_64_value >> 32);
        timer.time_val = dut.csr.tval;
        proxy->timercpy(&timer);
    }

    proxy->exec(1);
}

int Difftest::step(std::uint64_t main_time) {
    (void)main_time;
    idx_commit_ = 0;

    if (!enabled()) {
        return STATE_RUNNING;
    }
    if (sim_over_) {
        return STATE_END;
    }

    while (idx_commit_ < DIFFTEST_COMMIT_WIDTH && dut.commit[idx_commit_].valid) {
        const instr_commit_t& commit = dut.commit[idx_commit_];
        progress_ = true;
        if (state != nullptr) {
            state->record_inst(commit.pc, commit.inst, commit.wen, commit.wdest, commit.wdata,
                               false);
        }
        ++idx_commit_;
    }

    if (idx_commit_ == 0 && !dut.excp.excp_valid) {
        return STATE_RUNNING;
    }

    if (idx_commit_ > 0) {
        dut.csr.this_pc = dut.commit[idx_commit_ - 1].pc;
    }

    do_first_instr_commit();
    if (!started_) {
        for (std::uint32_t i = 0; i < idx_commit_; ++i) {
            dut.commit[i].valid = 0;
        }
        return STATE_RUNNING;
    }

    if (proxy->estat_sync != nullptr) {
        for (std::uint32_t index = 0; index < idx_commit_; ++index) {
            if (dut.commit[index].csr_rstat) {
                proxy->estat_sync(dut.commit[index].csr_data, 0x00001fff);
            }
        }
    }

    for (std::uint32_t index = 0; index < idx_commit_; ++index) {
        do_instr_commit(index);
        dut.commit[index].valid = 0;
    }

    if (dut.excp.excp_valid && dut.excp.exception == 0) {
        if (dut.excp.interrupt != 0 && proxy->raise_intr != nullptr) {
            proxy->raise_intr(dut.excp.interrupt);
            return STATE_RUNNING;
        }
        if ((dut.csr.estat & 0x3) != 0) {
            return STATE_RUNNING;
        }
        std::fprintf(stderr, "difftest: warning: interrupt exception with no pending irq\n");
    }

    if (proxy->store_commit != nullptr) {
        for (std::uint32_t index = 0; index < idx_commit_; ++index) {
            if (dut.store[index].valid) {
                if (proxy->store_commit(dut.store[index].paddr, dut.store[index].data) != 0) {
                    std::fprintf(stderr,
                                 "difftest: store mismatch at pc=0x%08x paddr=0x%llx "
                                 "vaddr=0x%llx data=0x%llx\n",
                                 dut.commit[index].pc,
                                 static_cast<unsigned long long>(dut.store[index].paddr),
                                 static_cast<unsigned long long>(dut.store[index].vaddr),
                                 static_cast<unsigned long long>(dut.store[index].data));
                    return STATE_ABORT;
                }
            }
        }
    }

    for (std::uint32_t index = 0; index < idx_commit_; ++index) {
        if (dut.load[index].valid && ((dut.load[index].paddr & 0x00000000f8000000ULL) != 0)) {
            proxy->regcpy(dut_regs_ptr_, DIFFTEST_TO_REF, DIFF_TO_REF_GR);
        }
    }

    if (dut.excp.excp_valid) {
        if (dut.excp.exception != 0) {
            proxy->exec(1);
        } else if (dut.excp.interrupt != 0 && proxy->raise_intr != nullptr) {
            proxy->raise_intr(dut.excp.interrupt);
        }
    }

    proxy->regcpy(ref_regs_ptr_, REF_TO_DUT, REF_TO_DIFF_ALL);

    ref.csr.tval = dut.csr.tval;
    if (dut.excp.excp_valid) {
        dut.csr.this_pc = ref.csr.this_pc;
    }

    bool ecode_error = false;
    if ((dut.csr.estat | 0x00001fffU) != (ref.csr.estat | 0x00001fffU)) {
        std::fprintf(stderr, "difftest: warning: estat mismatch dut=0x%08x ref=0x%08x\n",
                     dut.csr.estat, ref.csr.estat);
        ecode_error = true;
    }

    for (int i = 0; i < DIFFTEST_NR_CSRREG; ++i) {
        if (!kCompareMask[i]) {
            dut_regs_ptr_[DIFFTEST_NR_GREG + i] = 0;
            ref_regs_ptr_[DIFFTEST_NR_GREG + i] = 0;
        }
    }

    if (ecode_error ||
        std::memcmp(dut_regs_ptr_, ref_regs_ptr_, DIFFTEST_NR_REG * sizeof(std::uint32_t)) != 0) {
        for (int i = 0; i < DIFFTEST_NR_REG; ++i) {
            if (dut_regs_ptr_[i] != ref_regs_ptr_[i]) {
                if (i < 32) {
                    std::fprintf(stderr,
                                 "difftest: %s(r%02d) mismatch at pc=0x%08x "
                                 "ref=0x%08x dut=0x%08x\n",
                                 kRegName[i], i, ref.csr.this_pc, ref_regs_ptr_[i],
                                 dut_regs_ptr_[i]);
                } else {
                    std::fprintf(stderr,
                                 "difftest: %s mismatch at pc=0x%08x "
                                 "ref=0x%08x dut=0x%08x\n",
                                 kRegName[i], ref.csr.this_pc, ref_regs_ptr_[i],
                                 dut_regs_ptr_[i]);
                }
            }
        }
        return STATE_ABORT;
    }

    if (dut.trap.valid) {
        sim_over_ = true;
        return STATE_END;
    }

    return STATE_RUNNING;
}

void Difftest::display() {
    std::fprintf(stderr, "\n============== DUT Regs ==============\n");
    for (int i = 0; i < 32; ++i) {
        std::fprintf(stderr, "%s(r%2d): 0x%08x%s", kRegName[i], i, dut.regs.gpr[i],
                     (i % 4 == 3) ? "\n" : " ");
    }
    std::fprintf(stderr, "pc: 0x%08x\n", dut.csr.this_pc);
    std::fprintf(stderr, "CRMD: 0x%08x,    PRMD: 0x%08x,   EUEN: 0x%08x\n",
                 dut.csr.crmd, dut.csr.prmd, dut.csr.euen);
    std::fprintf(stderr, "ECFG: 0x%08x,   ESTAT: 0x%08x,    ERA: 0x%08x\n",
                 dut.csr.ecfg, dut.csr.estat, dut.csr.era);
    std::fprintf(stderr, "BADV: 0x%08x,  EENTRY: 0x%08x, LLBCTL: 0x%08x\n",
                 dut.csr.badv, dut.csr.eentry, dut.csr.llbctl);
    std::fprintf(stderr, "INDEX: 0x%08x, TLBEHI: 0x%08x, TLBELO0: 0x%08x, TLBELO1: 0x%08x\n",
                 dut.csr.tlbidx, dut.csr.tlbehi, dut.csr.tlbelo0, dut.csr.tlbelo1);
    std::fprintf(stderr, "ASID: 0x%08x, TLBRENTRY: 0x%08x, DMW0: 0x%08x, DMW1: 0x%08x\n",
                 dut.csr.asid, dut.csr.tlbrentry, dut.csr.dmw0, dut.csr.dmw1);

    if (enabled() && proxy->isa_reg_display != nullptr) {
        std::fprintf(stderr, "\n============== REF Regs ==============\n");
        proxy->isa_reg_display();
    }
}
