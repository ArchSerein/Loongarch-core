# ==========================================
# 1. Project Paths
# ==========================================
ROOT_DIR	:= $(shell pwd)
BUILD_DIR      := $(ROOT_DIR)/build
BDIR           := $(BUILD_DIR)/bdir
IDIR           := $(BUILD_DIR)/info
VDIR           := $(BUILD_DIR)/verilog
OBJDIR         := $(BUILD_DIR)/obj_dir
EXAMPLES_DIR   := $(abspath $(ROOT_DIR)/../chiplab/software/examples)
BSIM_RUNNER    := $(ROOT_DIR)/bluesim/bin/ubuntu.exe
TEST_NAME      := $(strip $(TEST))
TEST_KEY       := $(if $(TEST_NAME),$(subst /,_,$(TEST_NAME)),unset)
TEST_BIN_INFO  := $(BUILD_DIR)/test-bin.$(TEST_KEY).path

ifeq ($(filter nscscc_perf/%,$(TEST_NAME)),)
TEST_DIR       := $(EXAMPLES_DIR)/$(TEST_NAME)
TEST_BUILD_TARGET :=
else
TEST_DIR       := $(EXAMPLES_DIR)/nscscc_perf
TEST_BUILD_TARGET := $(patsubst nscscc_perf/%,%,$(TEST_NAME))
endif

ifeq ($(filter nscscc_perf/%,$(TEST_NAME)),)
ifneq ($(filter func/%,$(TEST_NAME)),)
TEST_EXPECTED_BIN := $(TEST_DIR)/obj/main.bin
else ifeq ($(TEST_NAME),nscscc_func)
TEST_EXPECTED_BIN := $(TEST_DIR)/obj/main.bin
else
TEST_EXPECTED_BIN := $(TEST_DIR)/obj/$(notdir $(TEST_NAME)).bin
endif
else
TEST_EXPECTED_BIN := $(EXAMPLES_DIR)/nscscc_perf/obj/$(TEST_BUILD_TARGET)/inst_data.bin
endif
-include $(ROOT_DIR)/include/config/auto.conf
-include $(ROOT_DIR)/include/config/auto.conf.cmd

# ==========================================
# 2. Connectal Configuration
# ==========================================
CONNECTALDIR   ?= /opt/connectal
CONNECTAL_MAKEFILE := $(CONNECTALDIR)/Makefile.connectal
BOARD          ?= bluesim
PROJECTDIR     ?= $(BOARD)

# Interface Definitions
# Structure: InterfaceType:WrapperModuleInstanceName.SubInterfaceName
S2H_INTERFACES = SimRequest:SimConnectalWrapper.request
H2S_INTERFACES = SimConnectalWrapper:SimIndication

# Explicitly list BSV files so topgen can find SimRequest and SimIndication
BSVFILES += \
    $(ROOT_DIR)/include/Types.bsv \
    $(ROOT_DIR)/include/SimInterfaces.bsv \
    $(ROOT_DIR)/include/AxiTypes.bsv \
    $(ROOT_DIR)/include/AxiMem.bsv \
    $(ROOT_DIR)/include/CoreAxiTop.bsv \
    $(ROOT_DIR)/Tb.bsv \
    $(ROOT_DIR)/include/SimConnectalWrapper.bsv

# Search paths for bsc and Connectal
BSVPATH += \
    $(ROOT_DIR) \
    $(ROOT_DIR)/include \
    $(CONNECTALDIR)/bsv

# C++ Sources for Connectal simulation
CPPFILES += $(ROOT_DIR)/csrc/bsim_main.cpp  \
            $(ROOT_DIR)/csrc/tb_memory.cpp

# C++ Sources for Verilator simulation
VERILATOR_CPPFILES = $(ROOT_DIR)/csrc/sim_main.cpp  \
            $(ROOT_DIR)/csrc/tb_memory.cpp

ifeq ($(CONFIG_DIFFTEST),y)
CPPFILES += $(ROOT_DIR)/csrc/difftest.cpp
VERILATOR_CPPFILES += $(ROOT_DIR)/csrc/difftest.cpp
endif

LDLIBS += -ldl

# Connectal Compilation Flags
SOFTWARE_SOCKET_NAME = /tmp/connectal$(USER)
export SOFTWARE_SOCKET_NAME

CONNECTALFLAGS += --bscflags " -steps-max-intervals 50 +RTS -K256M -RTS"
CONNECTALFLAGS += --bscflags " -show-schedule"

# ==========================================
# 3. Verilator Configuration
# ==========================================
VERILATOR_TOP  := mkTb
CORE_AXI_TOP   := mkCoreAxiTop
BSC            := bsc
VERILATOR      := verilator
SIM_BIN        := $(OBJDIR)/sim

MAX_CYCLES     ?= 100000000
START_PC       ?= 0
RUN_START_PC   ?= 0x1c000000

BSV_DPI_SRCS   := $(wildcard $(VDIR)/*.c) $(wildcard $(VDIR)/*.cc) $(wildcard $(VDIR)/*.cpp)

BSC_FLAGS := -u -verilog -vsim $(VERILATOR) -g $(VERILATOR_TOP) \
             -p +:$(ROOT_DIR)/include \
             -bdir $(BDIR) \
             -info-dir $(IDIR) \
             -vdir $(VDIR)

BSC_CORE_FLAGS := -u -verilog -vsim $(VERILATOR) -g $(CORE_AXI_TOP) \
                  -p +:$(ROOT_DIR)/include \
                  -bdir $(BDIR) \
                  -info-dir $(IDIR) \
                  -vdir $(VDIR)

VERILATOR_FLAGS := -Wno-STMTDLY --no-timing --cc --exe --build --trace -y $(shell dirname $(shell which bsc))/../lib/Verilog \
                   --top-module $(VERILATOR_TOP) \
                   -Mdir $(OBJDIR) \
                   -o sim \
                   -CFLAGS "-std=c++14 -O2"

# ==========================================
# 4. Build Targets
# ==========================================

# Default target must be first
default: sim

.PHONY: default sim bsim verilator-sim core-verilog run test-bin list-tests clean

# Run both Connectal-Bluesim and Verilator builds
ifneq ($(wildcard $(CONNECTAL_MAKEFILE)),)
sim: bsim verilator-sim
bsim: build.$(BOARD)
else
sim: verilator-sim
bsim:
	@echo "Connectal is not available at $(CONNECTAL_MAKEFILE)"
	@exit 1
endif

# Verilator execution
verilator-sim: $(SIM_BIN)
	$(SIM_BIN) --max-cycles $(MAX_CYCLES) --start-pc $(START_PC)

# Generate core RTL with AXI top-level wrapper.
core-verilog: $(VDIR)/$(CORE_AXI_TOP).v
	python3 $(ROOT_DIR)/scripts/gen_axi_wrapper.py

# Build a software test image and record the resolved bin path in build/test-bin.<test>.path.
# Examples:
#   make test-bin TEST=hello_world
#   make test-bin TEST=func/func_lab3
#   make test-bin TEST=nscscc_perf/coremark
test-bin:
	@if [ -z "$(TEST)" ]; then \
		echo "Usage: make test-bin TEST=<example>"; \
		echo "Examples: hello_world, func/func_lab3, nscscc_perf/coremark"; \
		exit 2; \
	fi
	@$(MAKE) "$(TEST_BIN_INFO)" TEST="$(TEST)"
	@echo "==> Using image: $$(cat "$(TEST_BIN_INFO)")"

# Build the Bluesim runner and the selected test image, then execute the test.
run:
	@if [ -z "$(TEST)" ]; then \
		echo "Usage: make run TEST=<example>"; \
		echo "Examples: hello_world, func/func_lab3, nscscc_perf/coremark"; \
		exit 2; \
	fi
	@$(MAKE) "$(BSIM_RUNNER)" "$(TEST_BIN_INFO)" TEST="$(TEST)"
	@set -e; \
	mem_image=$$(cat "$(TEST_BIN_INFO)"); \
	if [ ! -f "$$mem_image" ]; then \
		echo "run: resolved mem image does not exist: $$mem_image"; \
		exit 1; \
	fi; \
	echo "==> Launching: $(BSIM_RUNNER) --mem-image $$mem_image --start-pc $(RUN_START_PC)"; \
	"$(BSIM_RUNNER)" --mem-image "$$mem_image" --start-pc "$(RUN_START_PC)"

$(BSIM_RUNNER):
	@echo "==> Building Bluesim runner"
	@$(MAKE) bsim
	@if [ ! -x "$(BSIM_RUNNER)" ]; then \
		echo "run: Bluesim runner not found after build: $(BSIM_RUNNER)"; \
		exit 1; \
	fi

$(TEST_EXPECTED_BIN):
	@if [ -z "$(TEST)" ]; then \
		echo "Usage: make test-bin TEST=<example>"; \
		exit 2; \
	fi
	@if [ ! -f "$(TEST_DIR)/Makefile" ]; then \
		echo "test-bin: unsupported TEST=$(TEST_NAME)"; \
		echo "test-bin: expected Makefile at $(TEST_DIR)/Makefile"; \
		echo "test-bin: try 'make list-tests'"; \
		exit 2; \
	fi
	@echo "==> Building test: $(TEST_NAME)"
	@if [ -n "$(TEST_BUILD_TARGET)" ]; then \
		$(MAKE) -C "$(TEST_DIR)" "$(TEST_BUILD_TARGET)"; \
	else \
		$(MAKE) -C "$(TEST_DIR)"; \
	fi
	@if [ ! -f "$@" ]; then \
		echo "test-bin: expected bin not found: $@"; \
		exit 1; \
	fi

$(TEST_BIN_INFO): $(TEST_EXPECTED_BIN) | $(BUILD_DIR)
	@printf '%s\n' "$(TEST_EXPECTED_BIN)" > "$@"

list-tests:
	@echo "Top-level examples:"; \
	find "$(EXAMPLES_DIR)" -maxdepth 1 -mindepth 1 -type d | sort | while read -r dir; do \
		if [ -f "$$dir/Makefile" ]; then \
			basename "$$dir"; \
		fi; \
	done
	@echo
	@echo "Functional tests:"; \
	if [ -d "$(EXAMPLES_DIR)/func" ]; then \
		find "$(EXAMPLES_DIR)/func" -maxdepth 1 -mindepth 1 -type d | sort | while read -r dir; do \
			if [ -f "$$dir/Makefile" ]; then \
				printf 'func/%s\n' "$$(basename "$$dir")"; \
			fi; \
		done; \
	fi
	@echo
	@echo "NSCSCC perf benches:"; \
	if [ -d "$(EXAMPLES_DIR)/nscscc_perf/bench" ]; then \
		find "$(EXAMPLES_DIR)/nscscc_perf/bench" -maxdepth 1 -mindepth 1 -type d | sort | while read -r dir; do \
			printf 'nscscc_perf/%s\n' "$$(basename "$$dir")"; \
		done; \
	fi

# ==========================================
# 5. Compilation Rules
# ==========================================

$(BUILD_DIR) $(BDIR) $(IDIR) $(VDIR) $(OBJDIR):
	mkdir -p $@

# Generate Verilog from BSV for Verilator
$(VDIR)/$(VERILATOR_TOP).v: $(ROOT_DIR)/Tb.bsv $(BUILD_DIR) $(BDIR) $(IDIR) $(VDIR)
	$(BSC) $(BSC_FLAGS) $<

$(VDIR)/$(CORE_AXI_TOP).v: $(ROOT_DIR)/include/CoreAxiTop.bsv $(ROOT_DIR)/Core.bsv $(BUILD_DIR) $(BDIR) $(IDIR) $(VDIR)
	$(BSC) $(BSC_CORE_FLAGS) $<

# Compile Verilator binary
$(SIM_BIN): $(VDIR)/$(VERILATOR_TOP).v $(ROOT_DIR)/csrc/sim_main.cpp $(OBJDIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
                $(VDIR)/*.v \
                $(BSV_DPI_SRCS) \
                $(VERILATOR_CPPFILES)

# ==========================================
# 6. Cleaning
# ==========================================
clean:
	rm -rf $(BOARD) SWSOCK0 $(BDIR) $(IDIR) $(VDIR) $(OBJDIR) $(TEST_BIN_INFO)

# ==========================================
# 7. Connectal Core Logic
# ==========================================
ifneq ($(wildcard $(CONNECTAL_MAKEFILE)),)
include $(CONNECTAL_MAKEFILE)
endif

CONFIG_MK := $(ROOT_DIR)/scripts/config.mk

.PHONY: menuconfig savedefconfig defconfig

menuconfig savedefconfig defconfig:
	$(MAKE) -f $(CONFIG_MK) $@
