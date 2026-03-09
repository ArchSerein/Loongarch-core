SHELL := /bin/bash

VERILATOR_TOP := mkTb
CONNECTAL_TOP := mkSimConnectalWrapper
TEST ?= smoke
MAX_CYCLES ?= 1000000
START_PC ?= 0

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
CONNECTALDIR ?= /opt/connectal
CONNECTAL_SIM_MAKEFILE ?= $(ROOT_DIR)/Makefile.bsim
CONNECTAL_SIM_BIN ?= $(ROOT_DIR)/bin/ubuntu.exe

LA32R_PREFIX ?= loongarch32r-linux-gnusf
LA32R_GCC := $(LA32R_PREFIX)-gcc
LA32R_OBJCOPY := $(LA32R_PREFIX)-objcopy

TEST_SRC := $(TEST_DIR)/$(TEST).S
TEST_LD := $(TEST_DIR)/link.ld
TEST_ELF := $(BUILD_DIR)/$(TEST).elf
TEST_BIN := $(BUILD_DIR)/$(TEST).bin
MEM_IMAGE := $(BUILD_DIR)/mem.bin
TB_MEM_IMAGE ?= $(MEM_IMAGE)
SIM_BIN := $(OBJDIR)/sim
BSV_DPI_SRCS := $(wildcard $(VDIR)/*.c) $(wildcard $(VDIR)/*.cc) $(wildcard $(VDIR)/*.cpp)

# Connectal-style software/hardware interface registration hooks.
S2H_INTERFACES ?= SimRequest:SimConnectalWrapper.request
H2S_INTERFACES ?= SimConnectalWrapper:SimIndication

ifeq ($(abspath $(TB_MEM_IMAGE)),$(abspath $(MEM_IMAGE)))
SIM_IMAGE_DEPS := $(MEM_IMAGE)
else
SIM_IMAGE_DEPS := check-mem-image
endif

BSV_SEARCH_PATH := +:$(ROOT_DIR):$(ROOT_DIR)/include:$(ROOT_DIR)/../Project/src/includes
BSC_FLAGS := -u -verilog -vsim $(BSC_VSIM) -g $(VERILATOR_TOP) \
	-p $(BSV_SEARCH_PATH) \
	-bdir $(BDIR) \
	-info-dir $(IDIR) \
	-vdir $(VDIR) \
	$(BSC_EXTRA_FLAGS)

VERILATOR_FLAGS := --cc --exe --build --trace \
	--top-module $(VERILATOR_TOP) \
	-Mdir $(OBJDIR) \
	-o sim \
	-CFLAGS "-std=c++17 -O2"

default: sim

$(BUILD_DIR) $(BDIR) $(IDIR) $(VDIR) $(OBJDIR):
	mkdir -p $@

.PHONY: default sim bsim verilator-sim clean image program check-bsc check-verilator check-loongarch-tools check-mem-image check-connectal

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

check-connectal:
	@test -f $(CONNECTALDIR)/Makefile.connectal || { \
		echo "error: missing $(CONNECTALDIR)/Makefile.connectal (set CONNECTALDIR=... if needed)"; \
		exit 1; \
	}
	@test -f $(CONNECTAL_SIM_MAKEFILE) || { \
		echo "error: missing $(CONNECTAL_SIM_MAKEFILE)"; \
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

check-mem-image:
	@test -f $(TB_MEM_IMAGE) || { \
		echo "error: TB_MEM_IMAGE does not exist: $(TB_MEM_IMAGE)"; \
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

bsim: $(SIM_IMAGE_DEPS) check-connectal
	$(MAKE) -f $(CONNECTAL_SIM_MAKEFILE) \
		CONNECTALDIR=$(CONNECTALDIR) \
		CONNECTAL_TOP=$(CONNECTAL_TOP) \
		S2H_INTERFACES='$(S2H_INTERFACES)' \
		H2S_INTERFACES='$(H2S_INTERFACES)'
	TB_MEM_IMAGE=$(TB_MEM_IMAGE) $(CONNECTAL_SIM_BIN) --start-pc $(START_PC)

$(VDIR)/$(VERILATOR_TOP).v: Tb.bsv | check-bsc $(BUILD_DIR) $(BDIR) $(IDIR) $(VDIR)
	$(BSC) $(BSC_FLAGS) $<

$(SIM_BIN): $(VDIR)/$(VERILATOR_TOP).v csrc/sim_main.cpp | check-verilator $(OBJDIR)
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(VDIR)/*.v \
		$(BSV_DPI_SRCS) \
		csrc/sim_main.cpp

verilator-sim: $(SIM_IMAGE_DEPS) $(SIM_BIN)
	TB_MEM_IMAGE=$(TB_MEM_IMAGE) $(SIM_BIN) --max-cycles $(MAX_CYCLES) --start-pc $(START_PC)

sim: bsim verilator-sim

clean:
	rm -rf $(BUILD_DIR) bluesim bin obj sw hw generatedbsv
