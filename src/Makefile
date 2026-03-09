# ==========================================
# 1. Project Paths
# ==========================================
ROOT_DIR       := $(shell pwd)
BUILD_DIR      := $(ROOT_DIR)/build
BDIR           := $(BUILD_DIR)/bdir
IDIR           := $(BUILD_DIR)/info
VDIR           := $(BUILD_DIR)/verilog
OBJDIR         := $(BUILD_DIR)/obj_dir

# ==========================================
# 2. Connectal Configuration
# ==========================================
CONNECTALDIR   ?= /opt/connectal
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
    $(ROOT_DIR)/Tb.bsv \
    $(ROOT_DIR)/include/SimConnectalWrapper.bsv

# Search paths for bsc and Connectal
BSVPATH += \
    $(ROOT_DIR) \
    $(ROOT_DIR)/include \
    $(CONNECTALDIR)/bsv

# C++ Sources for Connectal simulation
CPPFILES += $(ROOT_DIR)/csrc/bsim_main.cpp

# Connectal Compilation Flags
SOFTWARE_SOCKET_NAME = /tmp/connectal$(USER)
export SOFTWARE_SOCKET_NAME

CONNECTALFLAGS += --bscflags " -steps-max-intervals 50 +RTS -K256M -RTS"
CONNECTALFLAGS += --bscflags " -show-schedule"

# ==========================================
# 3. Verilator Configuration
# ==========================================
VERILATOR_TOP  := mkTb
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

VERILATOR_FLAGS := --cc --exe --build --trace \
                   --top-module $(VERILATOR_TOP) \
                   -Mdir $(OBJDIR) \
                   -o sim \
                   -CFLAGS "-std=c++17 -O2"

# ==========================================
# 4. Build Targets
# ==========================================

# Default target must be first
default: sim

.PHONY: default sim bsim verilator-sim clean

# Run both Connectal-Bluesim and Verilator builds
sim: bsim verilator-sim

# Trigger Connectal standard build flow
bsim: build.$(BOARD)

# Verilator execution
verilator-sim: $(SIM_BIN)
	TB_MEM_IMAGE=$(TB_MEM_IMAGE) $(SIM_BIN) --max-cycles $(MAX_CYCLES) --start-pc $(START_PC)

# ==========================================
# 5. Compilation Rules
# ==========================================

$(BUILD_DIR) $(BDIR) $(IDIR) $(VDIR) $(OBJDIR):
	mkdir -p $@

# Generate Verilog from BSV for Verilator
$(VDIR)/$(VERILATOR_TOP).v: $(ROOT_DIR)/Tb.bsv $(BUILD_DIR) $(BDIR) $(IDIR) $(VDIR)
	$(BSC) $(BSC_FLAGS) $<

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
	rm -rf $(BUILD_DIR) $(BOARD)

# ==========================================
# 7. Connectal Core Logic
# ==========================================
include $(CONNECTALDIR)/Makefile.connectal
