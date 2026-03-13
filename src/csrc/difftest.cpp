#include "difftest.hpp"

#include <cassert>
#include <cerrno>
#include <cstring>
#include <cstdlib>
#include <dlfcn.h>
#include <memory>
#include <unistd.h>

#include <string>

namespace {

static const char* kDefaultRefSoPath =
    "/root/Loongarch-core/chiplab/toolchains/nemu/la32r-nemu-interpreter-so";

static const char* kGregName[32] = {
    "r0", "ra", "tp", "sp", "a0", "a1", "a2", "a3",
    "a4", "a5", "a6", "a7", "t0", "t1", "t2", "t3",
    "t4", "t5", "t6", "t7", "t8", "x",  "fp", "s0",
    "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8",
};

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
    if (!ref_so_path.empty()) {
        ref_so_path_ = ref_so_path;
    } else {
        ref_so_path_ = kDefaultRefSoPath;
    }

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
        std::fprintf(stderr, "difftest: dlopen(%s) failed: %s\n",
                     ref_so_path_.c_str(), dlerror());
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
    if (!enabled() || started_ || idx_commit_ == 0) {
        return;
    }

    if (!dut.commit[0].valid) {
        return;
    }

    if (dut.commit[0].pc != first_inst_pc_) {
        return;
    }

    if (!mem_synced_) {
        std::fprintf(stderr,
                     "difftest: warning: first commit seen before reference memory sync\n");
    }
    proxy->regcpy(dut_regs_ptr_, DIFFTEST_TO_REF, DIFF_TO_REF_GR);
    started_ = true;
    std::fprintf(stderr, "difftest: enabled at pc=0x%08x (core %d)\n", dut.commit[0].pc, coreid_);
}

void Difftest::do_instr_commit(int index) {
    if (!enabled()) {
        return;
    }
    if (dut.commit[index].skip) {
        proxy->regcpy(dut_regs_ptr_, DIFFTEST_TO_REF, DIFF_TO_REF_GR);
        return;
    }
    if (dut.commit[index].is_TLBFILL && proxy->tlbfill_index_set != nullptr) {
        proxy->tlbfill_index_set(dut.commit[index].TLBFILL_index);
    }
    proxy->exec(1);
}

int Difftest::step(std::uint64_t main_time) {
    (void)main_time;
    idx_commit_ = 0;
    progress_ = false;

    if (!enabled()) {
        return STATE_RUNNING;
    }
    if (sim_over_) {
        return STATE_END;
    }

    while (idx_commit_ < DIFFTEST_COMMIT_WIDTH && dut.commit[idx_commit_].valid) {
        instr_commit_t& c = dut.commit[idx_commit_];
        progress_ = true;
        dut.csr.this_pc = c.pc;
        if (c.wen && c.wdest != 0 && c.wdest < 32) {
            dut.regs.gpr[c.wdest] = c.wdata;
        }
        if (state != nullptr) {
            state->record_inst(c.pc, c.inst, c.wen, c.wdest, c.wdata, c.skip != 0);
        }
        ++idx_commit_;
    }

    if (idx_commit_ == 0 && !dut.excp.excp_valid) {
        return STATE_RUNNING;
    }

    do_first_instr_commit();
    if (!started_) {
        for (std::uint32_t i = 0; i < idx_commit_; ++i) {
            dut.commit[i].valid = 0;
        }
        return STATE_RUNNING;
    }

    for (std::uint32_t index = 0; index < idx_commit_; ++index) {
        do_instr_commit(index);
        proxy->regcpy(ref_regs_ptr_, REF_TO_DUT, REF_TO_DIFF_GR);
        ref.csr.this_pc = dut.commit[index].pc;

        for (int i = 0; i < 32; ++i) {
            if (dut.regs.gpr[i] != ref.regs.gpr[i]) {
                std::fprintf(stderr,
                             "difftest: %s(r%02d) mismatch at pc=0x%08x "
                             "ref=0x%08x dut=0x%08x (inst=0x%08x)\n",
                             kGregName[i], i, ref.csr.this_pc, ref.regs.gpr[i], dut.regs.gpr[i],
                             dut.commit[index].inst);
                return STATE_ABORT;
            }
        }
        dut.commit[index].valid = 0;
    }

    if (dut.excp.excp_valid && dut.excp.interrupt != 0 && proxy->raise_intr != nullptr) {
        proxy->raise_intr(dut.excp.interrupt);
    }
    if (dut.trap.valid) {
        sim_over_ = true;
        return STATE_END;
    }

    return STATE_RUNNING;
}

void Difftest::display() {
    std::fprintf(stderr, "\n============== DUT Shadow GPR ==============\n");
    for (int i = 0; i < 32; ++i) {
        std::fprintf(stderr, "%s(r%2d): 0x%08x%s", kGregName[i], i, dut.regs.gpr[i],
                     (i % 4 == 3) ? "\n" : " ");
    }
    std::fprintf(stderr, "pc: 0x%08x\n", dut.csr.this_pc);

    if (enabled() && proxy->isa_reg_display != nullptr) {
        std::fprintf(stderr, "\n============== REF Regs ==============\n");
        proxy->isa_reg_display();
    }
}
