SHELL := /bin/bash

TOP := mkTb
TEST ?= smoke
MAX_CYCLES ?= 1000000

ROOT_DIR := $(CURDIR)
BUILD_DIR := $(ROOT_DIR)/build
BDIR := $(BUILD_DIR)/bdir
IDIR := $(BUILD_DIR)/info
VDIR := $(BUILD_DIR)/verilog
OBJDIR := $(BUILD_DIR)/obj_dir
TEST_DIR := $(ROOT_DIR)/tests

BSC ?= bsc
VERILATOR ?= verilator
BSC_VSIM ?= verilator
BSC_EXTRA_FLAGS ?=

LA32R_PREFIX ?= loongarch32r-linux-gnusf
LA32R_GCC := $(LA32R_PREFIX)-gcc
LA32R_OBJCOPY := $(LA32R_PREFIX)-objcopy

TEST_SRC := $(TEST_DIR)/$(TEST).S
TEST_LD := $(TEST_DIR)/link.ld
TEST_ELF := $(BUILD_DIR)/$(TEST).elf
TEST_BIN := $(BUILD_DIR)/$(TEST).bin
MEM_IMAGE := $(BUILD_DIR)/mem.bin
SIM_BIN := $(OBJDIR)/sim
BSV_DPI_SRCS := $(wildcard $(VDIR)/*.c) $(wildcard $(VDIR)/*.cc) $(wildcard $(VDIR)/*.cpp)

BSV_SEARCH_PATH := +:$(ROOT_DIR)/include
BSC_FLAGS := -u -verilog -vsim $(BSC_VSIM) -g $(TOP) \
	-p $(BSV_SEARCH_PATH) \
	-bdir $(BDIR) \
	-info-dir $(IDIR) \
	-vdir $(VDIR) \
	$(BSC_EXTRA_FLAGS)

VERILATOR_FLAGS := --cc --exe --build --trace \
	--top-module $(TOP) \
	-Mdir $(OBJDIR) \
	-o sim \
	-CFLAGS "-std=c++17 -O2"

default: sim

$(BUILD_DIR) $(BDIR) $(IDIR) $(VDIR) $(OBJDIR):
	mkdir -p $@

.PHONY: default sim clean image program check-bsc check-verilator check-loongarch-tools

check-bsc:
	@command -v $(BSC) >/dev/null || { \
		echo "error: bsc not found in PATH (set BSC=... if needed)"; \
		exit 1; \
	}

check-verilator:
	@command -v $(VERILATOR) >/dev/null || { \
		echo "error: verilator not found in PATH (set VERILATOR=... if needed)"; \
		exit 1; \
	}

check-loongarch-tools:
	@command -v $(LA32R_GCC) >/dev/null || { \
		echo "error: $(LA32R_GCC) not found in PATH (set LA32R_PREFIX=... if needed)"; \
		exit 1; \
	}
	@command -v $(LA32R_OBJCOPY) >/dev/null || { \
		echo "error: $(LA32R_OBJCOPY) not found in PATH (set LA32R_PREFIX=... if needed)"; \
		exit 1; \
	}
	@test -f $(TEST_SRC) || { \
		echo "error: missing test source $(TEST_SRC)"; \
		exit 1; \
	}

$(TEST_ELF): $(TEST_SRC) $(TEST_LD) | check-loongarch-tools $(BUILD_DIR)
	$(LA32R_GCC) -nostdlib -nostartfiles -static -Wl,-T,$(TEST_LD) -o $@ $(TEST_SRC)

$(TEST_BIN): $(TEST_ELF)
	$(LA32R_OBJCOPY) -O binary $< $@

$(MEM_IMAGE): $(TEST_BIN) | $(BUILD_DIR)
	cp $< $@

program: $(TEST_BIN)

image: $(MEM_IMAGE)

$(VDIR)/$(TOP).v: Tb.bsv | check-bsc $(BUILD_DIR) $(BDIR) $(IDIR) $(VDIR)
	$(BSC) $(BSC_FLAGS) $<

$(SIM_BIN): $(VDIR)/$(TOP).v csrc/sim_main.cpp csrc/tb_mem.cpp | check-verilator $(OBJDIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(VDIR)/*.v \
		$(BSV_DPI_SRCS) \
		csrc/sim_main.cpp \
		csrc/tb_mem.cpp

sim: $(MEM_IMAGE) $(SIM_BIN)
	TB_MEM_IMAGE=$(MEM_IMAGE) $(SIM_BIN) --max-cycles $(MAX_CYCLES)

clean:
	rm -rf $(BUILD_DIR)
