# ==========================================
# 1. Project Paths
# ==========================================
ROOT_DIR       := $(shell pwd)
BUILD_DIR      := $(ROOT_DIR)/build
BDIR           := $(BUILD_DIR)/bdir
IDIR           := $(BUILD_DIR)/info
VDIR           := $(BUILD_DIR)/verilog
OBJDIR         := $(BUILD_DIR)/obj_dir
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
            $(ROOT_DIR)/csrc/tb_memory.cpp   \
            $(ROOT_DIR)/csrc/difftest.cpp

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

MAX_CYCLES     ?= 1000000
START_PC       ?= 0

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

VERILATOR_FLAGS := --cc --exe --build --trace \
                   --top-module $(VERILATOR_TOP) \
                   -Mdir $(OBJDIR) \
                   -o sim \
                   -CFLAGS "-std=c++11 -O2"

# ==========================================
# 4. Build Targets
# ==========================================

# Default target must be first
default: sim

.PHONY: default sim bsim verilator-sim core-verilog clean

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
	TB_MEM_IMAGE=$(TB_MEM_IMAGE) $(SIM_BIN) --max-cycles $(MAX_CYCLES) --start-pc $(START_PC)

# Generate core RTL with AXI top-level wrapper.
core-verilog: $(VDIR)/$(CORE_AXI_TOP).v

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
                $(ROOT_DIR)/csrc/sim_main.cpp

# ==========================================
# 6. Cleaning
# ==========================================
clean:
	rm -rf $(BOARD) SWSOCK0

# ==========================================
# 7. Connectal Core Logic
# ==========================================
ifneq ($(wildcard $(CONNECTAL_MAKEFILE)),)
include $(CONNECTAL_MAKEFILE)
endif

include $(ROOT_DIR)/scripts/config.mk
