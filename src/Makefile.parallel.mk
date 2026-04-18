# ==========================================
# 1. Project Paths
# ==========================================
ROOT_DIR	:= $(shell pwd)
BUILD_DIR      := $(ROOT_DIR)/build
BDIR           := $(BUILD_DIR)/bdir
IDIR           := $(BUILD_DIR)/info
VDIR           := $(BUILD_DIR)/verilog

# Only create directories if 'core-verilog' is among the goals
ifneq ($(filter core-verilog,$(MAKECMDGOALS)),)
$(shell mkdir -p $(BDIR) $(IDIR) $(VDIR))
endif

EXAMPLES_DIR   := $(abspath $(ROOT_DIR)/../chiplab/software/examples)
BSIM_RUNNER    := $(BUILD_DIR)/bsim
BSIM_RAW_RUNNER := $(BUILD_DIR)/bsim.raw
BSIM_COMPAT_RUNNER := $(BUILD_DIR)/bsim-bdpi
BSIM_COMPAT_RAW_RUNNER := $(BUILD_DIR)/bsim-bdpi.raw
BDPI_RUNNER    := $(BSIM_RUNNER)
BDPI_RAW_RUNNER := $(BSIM_RAW_RUNNER)
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
CONFIG_BSIM ?= $(shell if grep -q '^# CONFIG_BSIM is not set' "$(ROOT_DIR)/.config" 2>/dev/null; then echo n; else echo y; fi)

# ==========================================
# 3. Simulator Configuration
# ==========================================
CORE_AXI_TOP   := mkCoreAxiTop
BSC            := bsc
CXX            ?= c++
JOBS           ?= $(shell nproc)
BSC_RESOLVED   := $(shell command -v $(BSC) 2>/dev/null)
BSC_PREFIX     := $(if $(BSC_RESOLVED),$(abspath $(dir $(BSC_RESOLVED))/..),/opt/bsc)
BSC_LIB_DIR    := $(BSC_PREFIX)/lib
BLUESIM_DIR    := $(BSC_LIB_DIR)/Bluesim

MAX_CYCLES     ?= 100000000
START_PC       ?= 0
RUN_START_PC   ?= 0x1c000000

BSC_CORE_FLAGS := -u -verilog -g $(CORE_AXI_TOP) \
                  -p +:$(ROOT_DIR)/include \
                  -bdir $(BDIR) \
                  -info-dir $(IDIR) \
                  -vdir $(VDIR) \
                   -verilog-filter $(ROOT_DIR)/scripts/filter_bsv.sh

BDPI_TOP       := mkTbBDPI
BDPI_BDIR      := $(BUILD_DIR)/bdpi_bdir
BDPI_IDIR      := $(BUILD_DIR)/bdpi_info
BDPI_SIMDIR    := $(BUILD_DIR)/bdpi_sim

BDPI_BSC_FLAGS := -u -sim -g $(BDPI_TOP) \
                  -p +:$(ROOT_DIR)/include \
                  -bdir $(BDPI_BDIR) \
                  -info-dir $(BDPI_IDIR) \
                  -simdir $(BDPI_SIMDIR)

BDPI_LINK_FLAGS := -sim -e $(BDPI_TOP) \
                   -p +:$(ROOT_DIR)/include \
                   -bdir $(BDPI_BDIR) \
                   -simdir $(BDPI_SIMDIR)

BDPI_CPPFILES = $(ROOT_DIR)/csrc/bsim_bdpi.cpp \
                $(ROOT_DIR)/csrc/tb_memory.cpp

ifeq ($(CONFIG_DIFFTEST),y)
BDPI_CPPFILES += $(ROOT_DIR)/csrc/difftest.cpp
endif

BDPI_OBJS = $(patsubst $(ROOT_DIR)/csrc/%.cpp,$(BDPI_SIMDIR)/%.o,$(BDPI_CPPFILES))

# ==========================================
# 4. Build Targets
# ==========================================

# Default target must be first
default: bsim

.PHONY: default bsim bsim-bdpi core-verilog run run-bdpi test-bin list-tests clean

ifeq ($(CONFIG_BSIM),y)
bsim: $(BSIM_RUNNER)
else
bsim:
	@echo "CONFIG_BSIM is disabled; enable it with menuconfig before building Bluesim"
	@exit 1
endif

bsim-bdpi: $(BSIM_COMPAT_RUNNER)

# Generate core RTL with AXI top-level wrapper.
core-verilog: $(VDIR)/$(CORE_AXI_TOP).v
	find build/verilog -type f -name "*.v" \
		-exec sed -i '/`ifdef BSV_NO_INITIAL_BLOCKS/,/`endif/d' {} +
	find build/verilog -type f -name "*.v" \
		-exec sed -i '/`ifdef BSV_POSITIVE_RESET/,/`endif/c\
`define BSV_RESET_VALUE 1'\''b1\
`define BSV_RESET_EDGE posedge' {} +
	@echo "==== Updating myCPU Verilog files ===="
	rm -rf $(ROOT_DIR)/../chiplab/IP/myCPU/*
	cp build/verilog/*.v $(ROOT_DIR)/../chiplab/IP/myCPU/
	cp  /opt/bsc/lib/Verilog/RevertReg.v \
    	/opt/bsc/lib/Verilog/FIFO*.v \
    	/opt/bsc/lib/Verilog/RegFile*.v \
    	/opt/bsc/lib/Verilog/CReg*.v $(ROOT_DIR)/../chiplab/IP/myCPU/
	find $(ROOT_DIR)/../chiplab/IP/myCPU/ -type f -name "*.v" -exec $(ROOT_DIR)/scripts/filter_bsv.sh {} +
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
	if [ -n "$(DIFF_REF_SO)" ]; then \
		set -- --diff-ref-so "$(DIFF_REF_SO)"; \
	else \
		set --; \
	fi; \
	echo "==> Launching: $(BSIM_RUNNER) --mem-image $$mem_image --start-pc $(RUN_START_PC) $$*"; \
	"$(BSIM_RUNNER)" --mem-image "$$mem_image" --start-pc "$(RUN_START_PC)" "$$@"
	rm -f "$(TEST_BIN_INFO)"

run-bdpi: run

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

$(BUILD_DIR) $(BDIR) $(IDIR) $(VDIR) $(BDPI_BDIR) $(BDPI_IDIR) $(BDPI_SIMDIR):
	mkdir -p $@

# Rule to compile C++ files to objects in BDPI_SIMDIR
$(BDPI_SIMDIR)/%.o: $(ROOT_DIR)/csrc/%.cpp | $(BDPI_SIMDIR)
	$(CXX) -std=c++14 -O2 -Wall -Wno-unused -c -I$(BDPI_SIMDIR) -I$(BLUESIM_DIR) -o $@ $<

# 1. Generate dependencies
DEP_FILE      := $(BUILD_DIR)/.depends
BDPI_DEP_FILE := $(BUILD_DIR)/.bdpi_depends

DEP_ROOTS := $(ROOT_DIR)/include/SimBDPI.bsv
ifneq ($(filter core-verilog,$(MAKECMDGOALS)),)
DEP_ROOTS += $(ROOT_DIR)/include/CoreAxiTop.bsv
endif
ALL_BSV_SRCS := $(wildcard $(ROOT_DIR)/*.bsv $(ROOT_DIR)/include/*.bsv)

$(DEP_FILE): $(ALL_BSV_SRCS) scripts/gen_bsv_deps.py | $(BUILD_DIR) $(BDIR)
	@echo "Generating Verilog dependencies..."
	python3 scripts/gen_bsv_deps.py $(BDIR) "$(ROOT_DIR):$(ROOT_DIR)/include" $(DEP_ROOTS) > $@

$(BDPI_DEP_FILE): $(ALL_BSV_SRCS) scripts/gen_bsv_deps.py | $(BUILD_DIR) $(BDPI_BDIR)
	@echo "Generating Bluesim dependencies..."
	python3 scripts/gen_bsv_deps.py $(BDPI_BDIR) "$(ROOT_DIR):$(ROOT_DIR)/include" $(ROOT_DIR)/include/SimBDPI.bsv > $@

-include $(DEP_FILE)
-include $(BDPI_DEP_FILE)

BDPI_MODEL_HEADER := $(BDPI_SIMDIR)/model_$(BDPI_TOP).h
BDPI_MODEL_HEADER_STAMP := $(BDPI_SIMDIR)/.model_header.stamp

# The Bluesim link step materializes model_*.h and the generated simulator
# objects under $(BDPI_SIMDIR). bsim_bdpi.cpp must wait for that phase.
$(BDPI_RAW_RUNNER): $(BDPI_BDIR)/SimBDPI.bo | $(BUILD_DIR) $(BDPI_BDIR) $(BDPI_IDIR) $(BDPI_SIMDIR)
	@echo "Generating Bluesim raw runner..."
	$(BSC) $(BDPI_LINK_FLAGS) -o $@ \
		-Xc++ -std=c++14 \
		-Xc++ -I$(BDPI_SIMDIR) \
		-Xc++ -I$(BLUESIM_DIR) \
		-Xl -ldl \
		$$(find "$(BDPI_BDIR)" -maxdepth 1 -name '*.ba' | sort) \
		$(BDPI_CPPFILES)

$(BDPI_MODEL_HEADER_STAMP): $(BDPI_RAW_RUNNER)
	@test -f "$(BDPI_MODEL_HEADER)" || { \
		echo "Missing generated Bluesim model header: $(BDPI_MODEL_HEADER)"; \
		exit 1; \
	}
	@touch $@

$(BDPI_SIMDIR)/bsim_bdpi.o: $(BDPI_MODEL_HEADER_STAMP)

# 2. Parallel BO compilation rules
# For Verilog
$(BDIR)/%.bo: | $(BDIR) $(IDIR) $(VDIR)
	@src="$(firstword $(wildcard $(ROOT_DIR)/$*.bsv $(ROOT_DIR)/include/$*.bsv))"; \
	if [ -z "$$src" ]; then \
		echo "Missing Verilog BSV source for $@"; \
		exit 1; \
	fi; \
	echo "Compiling $$src to .bo (Verilog)"; \
	$(BSC) -verilog -p +:$(ROOT_DIR)/include -bdir $(BDIR) -info-dir $(IDIR) -vdir $(VDIR) "$$src"

# For Bluesim (.bo and .ba are generated)
$(BDPI_BDIR)/%.bo: | $(BDPI_BDIR) $(BDPI_IDIR)
	@src="$(firstword $(wildcard $(ROOT_DIR)/$*.bsv $(ROOT_DIR)/include/$*.bsv))"; \
	if [ -z "$$src" ]; then \
		echo "Missing Bluesim BSV source for $@"; \
		exit 1; \
	fi; \
	echo "Compiling $$src to .ba (Bluesim)"; \
	$(BSC) -sim -p +:$(ROOT_DIR)/include -bdir $(BDPI_BDIR) -info-dir $(BDPI_IDIR) "$$src"

# 3. Generate Verilog for core
$(VDIR)/$(CORE_AXI_TOP).v: $(BDIR)/CoreAxiTop.bo | $(VDIR)
	$(BSC) $(BSC_CORE_FLAGS) $(ROOT_DIR)/include/CoreAxiTop.bsv

$(BSIM_COMPAT_RUNNER): $(BSIM_RUNNER) | $(BUILD_DIR)
	cp $< $@

$(BSIM_COMPAT_RAW_RUNNER): $(BSIM_RAW_RUNNER) | $(BUILD_DIR)
	cp $< $@

BDPI_BSV_DEPS = $(ROOT_DIR)/Core.bsv \
                $(wildcard $(ROOT_DIR)/include/*.bsv)

# Main Bluesim runner target
$(BDPI_RUNNER): $(BDPI_RAW_RUNNER) $(BDPI_OBJS) | $(BUILD_DIR) $(BDPI_SIMDIR)
	@echo "Linking Bluesim runner with $(JOBS) parallel C++ jobs..."
	$(CXX) -std=c++14 -O2 -Wall -Wno-unused \
		-I$(BDPI_SIMDIR) \
		-I$(BLUESIM_DIR) \
		-o $(BDPI_RUNNER) \
		$(BDPI_SIMDIR)/*.o \
		$(BLUESIM_DIR)/libbskernel.a \
		$(BLUESIM_DIR)/libbsprim.a \
		-ldl -lpthread

# ==========================================
# 6. Cleaning
# ==========================================
clean:
	rm -rf $(BDIR) $(IDIR) $(VDIR) \
		$(BDPI_BDIR) $(BDPI_IDIR) $(BDPI_SIMDIR) \
		$(DEP_FILE) $(BDPI_DEP_FILE) \
		$(BDPI_RUNNER) $(BDPI_RAW_RUNNER) $(BDPI_RAW_RUNNER).so \
		$(BSIM_COMPAT_RUNNER) $(BSIM_COMPAT_RAW_RUNNER) $(BSIM_COMPAT_RAW_RUNNER).so \
		$(TEST_BIN_INFO)

CONFIG_MK := $(ROOT_DIR)/scripts/config.mk

.PHONY: menuconfig savedefconfig defconfig

menuconfig savedefconfig defconfig:
	$(MAKE) -f $(CONFIG_MK) $@
