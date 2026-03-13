#pragma once

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <string>

#ifndef DIFFTEST_COMMIT_WIDTH
#define DIFFTEST_COMMIT_WIDTH 1
#endif

#ifndef DEBUG_INST_TRACE_SIZE
#define DEBUG_INST_TRACE_SIZE 32
#endif

#ifndef DEBUG_GROUP_TRACE_SIZE
#define DEBUG_GROUP_TRACE_SIZE 16
#endif

#define DIFF_PROXY NemuProxy

class NemuProxy {
private:
    void* handle_ = nullptr;
    bool initialized_ = false;
    std::string ref_so_path_;

    void* load_symbol(const char* symbol_name, bool required = true);

public:
    NemuProxy(int coreid, const std::string& ref_so_path = "");
    ~NemuProxy();

    bool ready() const {
        return initialized_;
    }

    const std::string& ref_so_path() const {
        return ref_so_path_;
    }

    void (*memcpy)(std::uint64_t nemu_addr, void* dut_buf, std::size_t n, bool direction) = nullptr;
    void (*regcpy)(void* dut, bool direction, bool do_csr) = nullptr;
    void (*csrcpy)(void* dut, bool direction) = nullptr;
    void (*uarchstatus_cpy)(void* dut, bool direction) = nullptr;
    int (*store_commit)(std::uint64_t saddr, std::uint64_t sdata) = nullptr;
    void (*exec)(std::uint64_t n) = nullptr;
    std::uint64_t (*guided_exec)(void* disambiguate_para) = nullptr;
    void (*raise_intr)(std::uint64_t no) = nullptr;
    void (*isa_reg_display)() = nullptr;
    void (*tlbfill_index_set)(std::uint32_t index) = nullptr;
    void (*timercpy)(void* dut) = nullptr;
    void (*estat_sync)(std::uint32_t index, std::uint32_t mask) = nullptr;
    int (*check_end)() = nullptr;
};

enum {
    STATE_RUNNING = 0,
    STATE_END,
    STATE_TIME_LIMIT,
    STATE_ABORT
};

enum { DIFFTEST_TO_DUT, DIFFTEST_TO_REF };
enum { REF_TO_DUT, DUT_TO_REF };
enum { REF_TO_DIFFTEST, DUT_TO_DIFFTEST };
enum { DIFF_TO_REF_GR = 0, DIFF_TO_REF_ALL };
enum { REF_TO_DIFF_GR = 0, REF_TO_DIFF_ALL };

enum retire_inst_type { RET_NORMAL = 0, RET_INT, RET_EXC };

typedef struct trap_event_t{
    std::uint8_t valid = 0;
    std::uint8_t code = 0;
    std::uint32_t pc = 0;
    std::uint64_t cycleCnt = 0;
    std::uint64_t instrCnt = 0;
} trap_event_t;

typedef struct excp_event_t{
    std::uint8_t excp_valid = 0;
    std::uint8_t eret = 0;
    std::uint32_t interrupt = 0;
    std::uint32_t exception = 0;
    std::uint32_t exceptionPC = 0;
    std::uint32_t exceptionIst = 0;
} excp_event_t;

typedef struct instr_commit_t{
    std::uint8_t valid = 0;
    std::uint32_t pc = 0;
    std::uint32_t inst = 0;
    std::uint8_t skip = 0;
    std::uint8_t is_TLBFILL = 0;
    std::uint8_t TLBFILL_index = 0;
    std::uint8_t is_CNTinst = 0;
    std::uint64_t timer_64_value = 0;
    std::uint8_t wen = 0;
    std::uint8_t wdest = 0;
    std::uint32_t wdata = 0;
    std::uint8_t csr_rstat = 0;
    std::uint32_t csr_data = 0;
} instr_commit_t;

typedef struct arch_greg_state_t{
    std::uint32_t gpr[32] = {0};
} arch_greg_state_t;

typedef struct __attribute__((packed)) arch_csr_state_t {
    std::uint32_t crmd = 0;
    std::uint32_t prmd = 0;
    std::uint32_t euen = 0;
    std::uint32_t ecfg = 0;
    std::uint32_t era = 0;
    std::uint32_t badv = 0;
    std::uint32_t eentry = 0;
    std::uint32_t tlbidx = 0;
    std::uint32_t tlbehi = 0;
    std::uint32_t tlbelo0 = 0;
    std::uint32_t tlbelo1 = 0;
    std::uint32_t asid = 0;
    std::uint32_t pgdl = 0;
    std::uint32_t pgdh = 0;
    std::uint32_t save0 = 0;
    std::uint32_t save1 = 0;
    std::uint32_t save2 = 0;
    std::uint32_t save3 = 0;
    std::uint32_t tid = 0;
    std::uint32_t tcfg = 0;
    std::uint32_t tval = 0;
    std::uint32_t llbctl = 0;
    std::uint32_t tlbrentry = 0;
    std::uint32_t dmw0 = 0;
    std::uint32_t dmw1 = 0;
    std::uint32_t estat = 0;
    std::uint32_t this_pc = 0;
} arch_csr_state_t;

typedef struct store_event_t{
    std::uint8_t valid = 0;
    std::uint64_t paddr = 0;
    std::uint64_t vaddr = 0;
    std::uint64_t data = 0;
} store_event_t;

typedef struct load_event_t{
    std::uint8_t valid = 0;
    std::uint64_t paddr = 0;
    std::uint64_t vaddr = 0;
} load_event_t;

typedef struct {
    trap_event_t trap;
    excp_event_t excp;
    instr_commit_t commit[DIFFTEST_COMMIT_WIDTH];
    arch_greg_state_t regs;
    arch_csr_state_t csr;
    store_event_t store[DIFFTEST_COMMIT_WIDTH];
    load_event_t load[DIFFTEST_COMMIT_WIDTH];
} difftest_core_state_t;

class DiffState {
public:
    void record_group(std::uint64_t pc, std::uint64_t count) {
        retire_group_pc_queue[retire_group_pointer] = pc;
        retire_group_cnt_queue[retire_group_pointer] = count;
        retire_group_pointer = (retire_group_pointer + 1) % DEBUG_GROUP_TRACE_SIZE;
    }

    void record_inst(std::uint64_t pc, std::uint32_t inst, std::uint8_t wen,
                     std::uint8_t wdest, std::uint64_t wdata, bool skip) {
        retire_inst_pc_queue[retire_inst_pointer] = pc;
        retire_inst_inst_queue[retire_inst_pointer] = inst;
        retire_inst_wen_queue[retire_inst_pointer] = wen;
        retire_inst_wdst_queue[retire_inst_pointer] = wdest;
        retire_inst_wdata_queue[retire_inst_pointer] = wdata;
        retire_inst_skip_queue[retire_inst_pointer] = skip;
        retire_inst_type_queue[retire_inst_pointer] = RET_NORMAL;
        retire_inst_pointer = (retire_inst_pointer + 1) % DEBUG_INST_TRACE_SIZE;
    }

private:
    int retire_inst_pointer = 0;
    std::uint64_t retire_inst_pc_queue[DEBUG_INST_TRACE_SIZE] = {0};
    std::uint32_t retire_inst_inst_queue[DEBUG_INST_TRACE_SIZE] = {0};
    std::uint64_t retire_inst_wen_queue[DEBUG_INST_TRACE_SIZE] = {0};
    std::uint32_t retire_inst_wdst_queue[DEBUG_INST_TRACE_SIZE] = {0};
    std::uint64_t retire_inst_wdata_queue[DEBUG_INST_TRACE_SIZE] = {0};
    std::uint32_t retire_inst_type_queue[DEBUG_INST_TRACE_SIZE] = {0};
    bool retire_inst_skip_queue[DEBUG_INST_TRACE_SIZE] = {0};

    int retire_group_pointer = 0;
    std::uint64_t retire_group_pc_queue[DEBUG_GROUP_TRACE_SIZE] = {0};
    std::uint32_t retire_group_cnt_queue[DEBUG_GROUP_TRACE_SIZE] = {0};
};

class Difftest {
private:
    int coreid_;
    std::uint32_t first_inst_pc_;
    bool started_ = false;
    bool sim_over_ = false;
    bool mem_synced_ = false;

    difftest_core_state_t dut = {};
    difftest_core_state_t ref = {};
    std::uint32_t* dut_regs_ptr_ = reinterpret_cast<std::uint32_t*>(&dut.regs);
    std::uint32_t* ref_regs_ptr_ = reinterpret_cast<std::uint32_t*>(&ref.regs);

    std::unique_ptr<DiffState> state;
    std::unique_ptr<DIFF_PROXY> proxy;

    std::uint32_t idx_commit_ = 0;
    bool progress_ = false;

    void do_first_instr_commit();
    void do_instr_commit(int index);

public:
    Difftest(int coreid, const std::string& ref_so_path = "", std::uint32_t first_inst_pc = 0);
    ~Difftest();

    bool enabled() const {
        return proxy != nullptr && proxy->ready();
    }

    void load_memory_image(const void* image, std::size_t nbytes, std::uint32_t nemu_addr = 0);

    int step(std::uint64_t main_time);
    void display();

    inline trap_event_t* get_trap_event() {
        return &(dut.trap);
    }
    inline excp_event_t* get_excp_event() {
        return &(dut.excp);
    }
    inline instr_commit_t* get_instr_commit(std::uint8_t index) {
        return &(dut.commit[index]);
    }
    inline arch_csr_state_t* get_csr_state() {
        return &(dut.csr);
    }
    inline arch_greg_state_t* get_greg_state() {
        return &(dut.regs);
    }

    inline store_event_t* get_store_event(std::uint8_t index) {
        return &(dut.store[index]);
    }
    inline load_event_t* get_load_event(std::uint8_t index) {
        return &(dut.load[index]);
    }

    inline bool get_trap_valid() const {
        return dut.trap.valid;
    }
    inline int get_trap_code() const {
        return dut.trap.code;
    }
    inline int get_proxy_check_end() const {
        if (proxy == nullptr || proxy->check_end == nullptr) {
            return 0;
        }
        return proxy->check_end();
    }
};
