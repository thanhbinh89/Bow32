# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# DDR2/DDR3 IP unit test: the whole bow_ddr IP (LiteDRAM controller core, DFI
# adapter, PHY, bridges, registers) in tb_bow_ddr.sv, self-checking (link
# up, JEDEC init from the generated init.csv through the CSR port, read
# calibration, hand over, window traffic with read-modify-write against a
# reference model, LiteDRAM BIST, error paths; see the testbench header).
#
#   make test        build and run CONFIGS (lb stub card ddr3) with SEED (1), JOBS (8)
#                    jobs; about 3 minutes (the pin-level models are the slow part)
#   make test-ci     the same (CI)
#   make seeds CFG=card SEEDS="1 2 3"   one configuration, several seeds (board delays
#                    and random traffic are drawn per seed)
#   make run CFG=lb SEED=3          one run: build/ddr_dv/<cfg>_s<seed>/sim.log
#   make run CFG=lb WAVES=1         with a waveform (DIR/waves.fst)
#   make rst         reset / clock-domain crossing corner cases (tb_bow_ddr_rst.sv:
#                    short CORE_RST pulses, CSR read right at the CORE_RST release,
#                    CORE_RST during window stores, SoC reset during a phase move,
#                    init_done cleared during a window access, DDR clocks lost
#                    with the MMCMs locked); part of make test
#
# Configurations (one Verilator model each, build/ddr_dv/obj_<cfg>):
#   lb     MPS4 loopback build: bow_ddr_lb (4 MiB) behind the pad wrapper's
#          loopback, DDR2 x8 (litedram_ddr2), 133.33 MHz, 504 phase steps
#   stub   bow_ddr_stub (DdrEn = 0) in place of bow_ddr (lb parameters)
#   card   DDR2 x8 card behind TXV0108 level shifters (ddr_board_model +
#          ddr_mem_model: JEDEC and pin timing checks), 133.33 MHz
#   ddr3   DDR3 x16 DLL-off on a direct board (litedram_ddr3, DM, RESET#),
#          125 MHz, 448 phase steps

REPO      := $(abspath ../../../..)
BUILD     ?= $(REPO)/build/ddr_dv
VERILATOR ?= verilator

CFG   ?= lb
SEED  ?= 1
WAVES ?= 0
JOBS  ?= 8
ARGS  ?=

CONFIGS ?= lb stub card ddr3
SEEDS   ?= 1 2 3 4

# --------------------------------------------------------- configurations
# Verilator -G parameters of tb_bow_ddr (bit parameters as -GName=1'b1) and
# the generated core of each configuration (init.csv)
G_lb    := -GDdrMem=2 -GClkHz=133333333 -GTckPs=7500 -GPsSteps=504 -GPhyKind=2 -GEmuBytes=4194304
CORE_lb := ddr2
G_stub    := $(G_lb) "-GStub=1'b1"
CORE_stub := ddr2
G_card    := -GDdrMem=2 -GClkHz=133333333 -GTckPs=7500 -GPsSteps=504 -GPhyKind=1 -GEmuBytes=0 \
             "-GLevelShift=1'b1"
CORE_card := ddr2
G_ddr3    := -GDdrMem=3 -GClkHz=125000000 -GTckPs=8000 -GPsSteps=448 -GPhyKind=1 -GEmuBytes=0 \
             "-GLevelShift=1'b0"
CORE_ddr3 := ddr3

# ------------------------------------------------------------------ build
DDR_F  ?= $(REPO)/hw/ip/ddr/ddr.f
FLISTS := -F $(REPO)/hw/ip/common/common.f -F $(REPO)/hw/ip/bus/bus.f -F $(DDR_F)
DV     := $(addprefix $(CURDIR)/,ddr_clk_model.sv bow_ddr_io_sim.sv ddr_board_model.sv \
          ddr_mem_model.sv tb_bow_ddr.sv)
SRCS   := $(shell find $(REPO)/hw/ip/ddr $(REPO)/hw/ip/common $(REPO)/hw/ip/bus \
            -name '*.sv' -o -name '*.v' -o -name '*.f')
TRACE  := $(if $(filter 1,$(WAVES)),--trace-fst --trace-structs,)
sim_bin = $(BUILD)/obj_$(1)$(if $(filter 1,$(WAVES)),_w)/Vtb_bow_ddr

build: $(foreach c,$(CONFIGS),$(call sim_bin,$(c)))

$(BUILD)/obj_%/Vtb_bow_ddr: $(SRCS)
	@mkdir -p $(BUILD)
	$(VERILATOR) --binary --timing -j $(JOBS) -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	  $(TRACE) --top-module tb_bow_ddr $(G_$(patsubst %_w,%,$*)) -Mdir $(BUILD)/obj_$* -o Vtb_bow_ddr \
	  $(FLISTS) $(DV) > $(BUILD)/build_$*.log 2>&1 || { tail -30 $(BUILD)/build_$*.log; exit 1; }

# ------------------------------------------------------------------ one run
RUN_DIR = $(BUILD)/$(CFG)_s$(SEED)
run: $(call sim_bin,$(CFG))
	@$(MAKE) --no-print-directory case CFG=$(CFG) SEED=$(SEED)

# (no build dependency: test runs the cases in parallel on built models)
case:
	@rm -rf $(RUN_DIR) && mkdir -p $(RUN_DIR)
	@cd $(RUN_DIR) && $(call sim_bin,$(CFG)) +SEED=$(SEED) +ddr_board_seed=$(SEED) \
	  +ddr_mem_seed=$(SEED) +INIT=$(REPO)/hw/ip/ddr/litedram/generated/$(CORE_$(CFG))/init.csv \
	  $(if $(filter 1,$(WAVES)),+WAVES) $(ARGS) > $(RUN_DIR)/sim.log 2>&1 || \
	  { echo "$(CFG)_s$(SEED): simulation failed, see $(RUN_DIR)/sim.log"; \
	    grep -m8 -E "ERROR|Error|FAIL|fatal" $(RUN_DIR)/sim.log; exit 1; }
	@grep -q "^tb_bow_ddr: PASS" $(RUN_DIR)/sim.log || \
	  { echo "$(CFG)_s$(SEED): testbench FAIL, see $(RUN_DIR)/sim.log"; \
	    grep -m8 -E "ERROR|FAIL" $(RUN_DIR)/sim.log; exit 1; }
	@echo "PASS $(CFG)_s$(SEED) ($$(grep -m1 '^tb_bow_ddr: PASS' $(RUN_DIR)/sim.log | sed 's/.* at //'))"

c/%:
	@$(MAKE) --no-print-directory case CFG=$(word 1,$(subst ., ,$*)) SEED=$(word 2,$(subst ., ,$*))

build-all:
	@$(MAKE) --no-print-directory -j2 build JOBS=4

test: build-all
	@$(MAKE) --no-print-directory -j$(JOBS) $(foreach c,$(CONFIGS),c/$(c).$(SEED)) rst
	@echo "ddr_dv: $(words $(CONFIGS)) / $(words $(CONFIGS)) configurations and the reset tests pass"

test-ci: test

seeds: $(call sim_bin,$(CFG))
	@$(MAKE) --no-print-directory -j$(JOBS) $(foreach s,$(SEEDS),c/$(CFG).$(s))

# ------------------------------------------- reset / CDC corner cases
RST_BIN := $(BUILD)/obj_rst/Vtb_bow_ddr_rst
RST_DIR := $(BUILD)/rst

$(RST_BIN): $(SRCS)
	@mkdir -p $(BUILD)
	$(VERILATOR) --binary --timing -j $(JOBS) -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	  --top-module tb_bow_ddr_rst -Mdir $(BUILD)/obj_rst -o Vtb_bow_ddr_rst \
	  $(FLISTS) $(CURDIR)/ddr_clk_model.sv $(CURDIR)/tb_bow_ddr_rst.sv > $(BUILD)/build_rst.log 2>&1 || \
	  { tail -30 $(BUILD)/build_rst.log; exit 1; }

rst: $(RST_BIN)
	@mkdir -p $(RST_DIR)
	@cd $(RST_DIR) && $(RST_BIN) > $(RST_DIR)/sim.log 2>&1 || \
	  { echo "rst: simulation failed, see $(RST_DIR)/sim.log"; exit 1; }
	@grep -q "^tb_bow_ddr_rst: PASS" $(RST_DIR)/sim.log || \
	  { echo "rst: testbench FAIL, see $(RST_DIR)/sim.log"; grep -m8 -E "ERROR|FAIL" $(RST_DIR)/sim.log; exit 1; }
	@echo "PASS rst ($$(grep -m1 '^tb_bow_ddr_rst: PASS' $(RST_DIR)/sim.log | sed 's/.* at //'))"

clean:
	rm -rf $(BUILD)

.PHONY: build build-all run case test test-ci seeds rst clean
SHELL := /bin/bash
