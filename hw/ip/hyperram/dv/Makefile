# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# HyperRAM IP unit test (tb_bow_hyperram.sv): the bow_hyperram RTL driven
# through its register slot and window like sw/common/src/bow_hyperram.c
# (enable, HW_RESET, read calibration with raw capture, CR0 / CR1, pattern
# calibration, write phase scan on the card), then window traffic, BIST,
# power states and error paths, against the DV models of this directory
# (board, S80KS2562 with the data sheet checks) or the RTL's loopback
# emulator; and the self-test of the models alone (tb_hyperram_model.sv).
#
#   make test        build and run IP_CONFIGS (lb card direct stub) with SEED (1) and ozf
#                    with SEED_ozf (8: a seed that needs RD_HOLD),
#                    JOBS (8) jobs; every case runs, then "hyperram_dv: n / 5 IP cases pass";
#                    about 1.5 minutes from scratch
#   make test-ci     the same (CI)
#   make test WAIVE="BIST_REFUSE WIN_IDLE"   the same with RTL issues reported as waived
#                    instead of failing the case (+WAIVE_<tag>, see tb_bow_hyperram.sv; both
#                    tags are fixed RTL issues, kept as regression checks)
#   make seeds CFG=card SEEDS="1 2 3"   one configuration, several seeds (board delays,
#                    device output timing, read clock phase and traffic per seed)
#   make run CFG=card SEED=3     one run: build/hyperram_dv/<cfg>_s<seed>/sim.log
#   make run CFG=card WAVES=1    with a waveform (DIR/waves.fst)
#   make run CFG=card ASSERT=1   Verilator --assert (unique / priority case checks; own
#                    model build/hyperram_dv/obj_<cfg>_a)
#   make rdhold SEEDS="1 8 13"   ozf with TIM0.RD_HOLD = 1 and 0 per seed: the read eyes
#                    and the outcome side by side (RD_HOLD = 0: the
#                    last byte of a read may be cut when CS# rises); a report, not a
#                    pass / fail target
#   make model       the models' self-test, MODEL_CONFIGS (card direct fast) with SEED
#   make model-seeds MCFG=card SEEDS="1 2"   /   make model-run MCFG=fast SEED=3
#   make lint        Verilator -Wall on the four models and both testbenches (warnings of
#                    the DV files only; the RTL is linted by the top level make lint)
#   make xsim CFG=card SEED=1 / make model-xsim MCFG=card SEED=1   one configuration
#                    under Vivado xsim (optional, XSIM_BIN; xelab --timescale 1ps/1ps:
#                    the RTL has no timescale)
#
# IP configurations (one Verilator model each, build/hyperram_dv/obj_<cfg>):
#   lb      MPS4 loopback build: pad twin in Loopback + bow_hyperram_dev (1 MiB), 100 MHz,
#           672 steps, also variable latency (the emulator's refresh collisions); the
#           emulator's DBG must stay 0
#   card    FMC+_DDR2_HyperRam card (TXV0108) + S80KS2562 model, 100 MHz, fixed latency 4,
#           write phase calibration
#   direct  direct board + S80KS2562 model, 166.67 MHz, 336 steps, latency 6, also variable
#           latency traffic (refresh collisions)
#   stub    bow_hyperram_stub (HrEn = 0): window bus errors, INFO.HR_EN = 0
#   ozf     the direct model with +hyperram_oz_free (the device may turn DQ off before the
#           last byte is out: TIM0.RD_HOLD = 1 must keep reads right)
# Model self-test configurations (build/hyperram_dv/obj_model_<cfg>): card, direct (100 MHz),
#   fast (166.67 MHz direct).

REPO      := $(abspath ../../../..)
BUILD     ?= $(REPO)/build/hyperram_dv
VERILATOR ?= verilator
XSIM_BIN  ?= /opt/xilinx/2025.2/Vivado/bin

CFG   ?= card
MCFG  ?= card
SEED  ?= 1
WAVES ?= 0
ASSERT ?= 0
JOBS  ?= 8
ARGS  ?=
WAIVE ?=
TAG   ?=

IP_CONFIGS    ?= lb card direct stub
MODEL_CONFIGS ?= card direct fast
SEEDS         ?= 1 2 3 4

VFLAGS := --binary --timing -j $(JOBS) -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD
TRACE  := $(if $(filter 1,$(WAVES)),--trace-fst --trace-structs,)
W      := $(if $(filter 1,$(WAVES)),_w,)
AFLAG  := $(if $(filter 1,$(ASSERT)),--assert,)
A      := $(if $(filter 1,$(ASSERT)),_a,)

# --------------------------------------------------------- IP configurations
# Verilator -G parameters of tb_bow_hyperram; X_*: the same for xelab
G_lb     := -GPhyKind=2 "-GHasLs=1'b0" -GTckPs=10000 -GClkHz=100000000 -GPsSteps=672 -GEmuBytes=1048576 \
            "-GVarLat=1'b1"
G_card   := -GPhyKind=1 "-GHasLs=1'b1" -GTckPs=10000 -GClkHz=100000000 -GPsSteps=672
G_direct := -GPhyKind=1 "-GHasLs=1'b0" -GTckPs=6000 -GClkHz=166666667 -GPsSteps=336 "-GVarLat=1'b1"
G_stub   := -GPhyKind=1 "-GHasLs=1'b1" "-GStub=1'b1" -GTckPs=10000 -GClkHz=100000000 -GPsSteps=672
X_lb     := PhyKind=2 HasLs=0 TckPs=10000 ClkHz=100000000 PsSteps=672 EmuBytes=1048576 VarLat=1
X_card   := PhyKind=1 HasLs=1 TckPs=10000 ClkHz=100000000 PsSteps=672
X_direct := PhyKind=1 HasLs=0 TckPs=6000 ClkHz=166666667 PsSteps=336 VarLat=1
X_stub   := PhyKind=1 HasLs=1 Stub=1 TckPs=10000 ClkHz=100000000 PsSteps=672
# cases that reuse another configuration's model with extra plusargs
BIN_ozf  := direct
ARGS_ozf := +hyperram_oz_free
bin_of    = $(or $(BIN_$(1)),$(1))

# ------------------------------------------------- model self-test configurations
GM_card   := "-GLevelShift=1'b1" -GTckPs=10000 -GPsSteps=672 "-GFastLatCode=4'b1111"
GM_direct := "-GLevelShift=1'b0" -GTckPs=10000 -GPsSteps=672 "-GFastLatCode=4'b1111"
GM_fast   := "-GLevelShift=1'b0" -GTckPs=6000 -GPsSteps=336 "-GFastLatCode=4'b0001"
XM_card   := LevelShift=1 TckPs=10000 PsSteps=672 FastLatCode=15
XM_direct := LevelShift=0 TckPs=10000 PsSteps=672 FastLatCode=15
XM_fast   := LevelShift=0 TckPs=6000 PsSteps=336 FastLatCode=1

# ------------------------------------------------------------------ sources
PKG     := $(REPO)/hw/ip/hyperram/rtl/bow_hyperram_pkg.sv
MODELS  := $(addprefix $(CURDIR)/,hyperram_clk_model.sv bow_hyperram_io_sim.sv \
           hyperram_board_model.sv hyperram_model.sv)
FLISTS  := -F $(REPO)/hw/ip/common/common.f -F $(REPO)/hw/ip/bus/bus.f -F $(REPO)/hw/ip/hyperram/hyperram.f
RTL     := $(shell find $(REPO)/hw/ip/hyperram $(REPO)/hw/ip/common $(REPO)/hw/ip/bus \
             -name '*.sv' -o -name '*.v' -o -name '*.f')
IP_SRCS := $(MODELS) $(CURDIR)/tb_bow_hyperram.sv
M_SRCS  := $(PKG) $(MODELS) $(CURDIR)/tb_hyperram_model.sv
ip_bin   = $(BUILD)/obj_$(call bin_of,$(1))$(W)$(A)/Vtb_bow_hyperram
m_bin    = $(BUILD)/obj_model_$(1)$(W)/Vtb_hyperram_model

build: $(foreach c,$(IP_CONFIGS),$(call ip_bin,$(c)))

$(BUILD)/obj_model_%/Vtb_hyperram_model: $(M_SRCS)
	@mkdir -p $(BUILD)
	$(VERILATOR) $(VFLAGS) $(TRACE) --top-module tb_hyperram_model $(GM_$(patsubst %_w,%,$*)) \
	  -Mdir $(BUILD)/obj_model_$* -o Vtb_hyperram_model $(M_SRCS) > $(BUILD)/build_model_$*.log 2>&1 || \
	  { tail -30 $(BUILD)/build_model_$*.log; exit 1; }

$(BUILD)/obj_%/Vtb_bow_hyperram: $(RTL) $(IP_SRCS)
	@mkdir -p $(BUILD)
	$(VERILATOR) $(VFLAGS) $(TRACE) $(AFLAG) --top-module tb_bow_hyperram $(G_$(firstword $(subst _, ,$*))) \
	  -Mdir $(BUILD)/obj_$* -o Vtb_bow_hyperram $(FLISTS) $(IP_SRCS) > $(BUILD)/build_$*.log 2>&1 || \
	  { tail -30 $(BUILD)/build_$*.log; exit 1; }

# ------------------------------------------------------------------ IP runs
RUN_DIR = $(BUILD)/$(CFG)$(TAG)$(A)_s$(SEED)
run: $(call ip_bin,$(CFG))
	@$(MAKE) --no-print-directory case CFG=$(CFG) SEED=$(SEED)

# (no build dependency: test runs the cases in parallel on built models)
case:
	@rm -rf $(RUN_DIR) && mkdir -p $(RUN_DIR)
	@cd $(RUN_DIR) && $(call ip_bin,$(CFG)) +SEED=$(SEED) +hyperram_clk_seed=$(SEED) \
	  +hyperram_board_seed=$(SEED) +hyperram_mem_seed=$(SEED) +hyperram_txn_log=txn.log \
	  $(ARGS_$(CFG)) $(addprefix +WAIVE_,$(WAIVE)) $(if $(filter 1,$(WAVES)),+WAVES) $(ARGS) \
	  > $(RUN_DIR)/sim.log 2>&1 || \
	  { echo "$(CFG)$(TAG)$(A)_s$(SEED): simulation failed, see $(RUN_DIR)/sim.log"; \
	    grep -m8 -E "ERROR|Error|FAIL|fatal" $(RUN_DIR)/sim.log; exit 1; }
	@grep -q "^tb_bow_hyperram: PASS" $(RUN_DIR)/sim.log || \
	  { echo "$(CFG)$(TAG)$(A)_s$(SEED): testbench FAIL, see $(RUN_DIR)/sim.log"; \
	    grep -m8 -E "tb_bow_hyperram: ERROR|ERROR \[|FAIL" $(RUN_DIR)/sim.log | cut -c1-240; exit 1; }
	@echo "PASS $(CFG)$(TAG)$(A)_s$(SEED) ($$(grep -m1 '^tb_bow_hyperram: PASS' $(RUN_DIR)/sim.log | sed 's/.* at //'))$$(grep -q 'tb_bow_hyperram: NOTE' $(RUN_DIR)/sim.log && echo ', with notes')$$(grep -q 'tb_bow_hyperram: WAIVED' $(RUN_DIR)/sim.log && echo ', RTL issues waived')"

c/%:
	@$(MAKE) --no-print-directory case CFG=$(word 1,$(subst ., ,$*)) SEED=$(word 2,$(subst ., ,$*))

build-all:
	@$(MAKE) --no-print-directory -j4 build JOBS=$(JOBS)

TEST_CFGS = $(IP_CONFIGS) ozf
# ozf runs with a seed whose device turns DQ off before the last byte is out
# when RD_HOLD = 0 (make rdhold: seeds 8 and 13): a broken RD_HOLD fails it
SEED_ozf  ?= 8
case_seed  = $(or $(SEED_$(1)),$(SEED))
TEST_RUNS  = $(foreach c,$(TEST_CFGS),$(c).$(call case_seed,$(c)))

test: build-all
	@$(MAKE) --no-print-directory -k -j$(JOBS) $(addprefix c/,$(TEST_RUNS)); rc=$$?; \
	  n=0; for r in $(TEST_RUNS); do c=$${r%.*}; s=$${r##*.}; \
	    grep -q "^tb_bow_hyperram: PASS" $(BUILD)/$${c}$(A)_s$${s}/sim.log 2>/dev/null && n=$$((n + 1)); \
	  done; \
	  echo "hyperram_dv: $$n / $(words $(TEST_CFGS)) IP cases pass ($(TEST_RUNS))"; exit $$rc

test-ci: test

seeds: $(call ip_bin,$(CFG))
	@$(MAKE) --no-print-directory -j$(JOBS) $(foreach s,$(SEEDS),c/$(CFG).$(s))

# RD_HOLD = 1 and 0 side by side (run directories ozf_rh1_s<n>, ozf_rh0_s<n>); the eye
# counts are the good points of the coarse ID0 sweep and of the pattern sweep
RH_WAIVE := BIST_REFUSE WIN_IDLE SLEEP_LOSS
rh/%:
	@$(MAKE) --no-print-directory case CFG=ozf SEED=$(word 2,$(subst ., ,$*)) TAG=_rh$(word 1,$(subst ., ,$*)) \
	  WAIVE="$(RH_WAIVE)" ARGS="+RD_HOLD=$(word 1,$(subst ., ,$*)) $(ARGS)" > /dev/null 2>&1 || true

rdhold: $(call ip_bin,direct)
	@$(MAKE) --no-print-directory -j$(JOBS) $(foreach s,$(SEEDS),rh/1.$(s) rh/0.$(s))
	@for s in $(SEEDS); do for h in 1 0; do \
	  f=$(BUILD)/ozf_rh$${h}_s$$s/sim.log; \
	  e1=$$(grep -m1 'eye (ID0)' $$f | cut -d'|' -f2 | tr -cd '#' | wc -c); \
	  e2=$$(grep -m1 'eye (pattern)' $$f | cut -d'|' -f2 | tr -cd '#' | wc -c); \
	  if grep -q "^tb_bow_hyperram: PASS" $$f; then r=passes; \
	  else r="fails: $$(grep -m1 'tb_bow_hyperram: ERROR' $$f | sed 's/.*ERROR //' | cut -c1-100)"; fi; \
	  echo "ozf_s$$s RD_HOLD=$$h: ID0 eye $$e1 points, pattern eye $$e2 points; $$r"; \
	done; done

# ----------------------------------------------------------- model self-test
M_RUN_DIR = $(BUILD)/model_$(MCFG)_s$(SEED)
model-run: $(call m_bin,$(MCFG))
	@$(MAKE) --no-print-directory model-case MCFG=$(MCFG) SEED=$(SEED)

model-case:
	@rm -rf $(M_RUN_DIR) && mkdir -p $(M_RUN_DIR)
	@cd $(M_RUN_DIR) && $(call m_bin,$(MCFG)) +SEED=$(SEED) +hyperram_clk_seed=$(SEED) \
	  +hyperram_board_seed=$(SEED) +hyperram_mem_seed=$(SEED) +hyperram_txn_log=txn.log \
	  $(if $(filter 1,$(WAVES)),+WAVES) $(ARGS) > $(M_RUN_DIR)/sim.log 2>&1 || \
	  { echo "model $(MCFG)_s$(SEED): simulation failed, see $(M_RUN_DIR)/sim.log"; \
	    grep -m8 -E "ERROR|Error|FAIL|fatal" $(M_RUN_DIR)/sim.log; exit 1; }
	@grep -q "^tb_hyperram_model: PASS" $(M_RUN_DIR)/sim.log || \
	  { echo "model $(MCFG)_s$(SEED): testbench FAIL, see $(M_RUN_DIR)/sim.log"; \
	    grep -m8 -E "tb_hyperram_model: ERROR|FAIL" $(M_RUN_DIR)/sim.log; exit 1; }
	@echo "PASS model $(MCFG)_s$(SEED) ($$(grep -m1 '^tb_hyperram_model: PASS' $(M_RUN_DIR)/sim.log | sed 's/.* at //'))"

m/%:
	@$(MAKE) --no-print-directory model-case MCFG=$(word 1,$(subst ., ,$*)) SEED=$(word 2,$(subst ., ,$*))

model-build: $(foreach c,$(MODEL_CONFIGS),$(call m_bin,$(c)))

model:
	@$(MAKE) --no-print-directory -j3 model-build JOBS=$(JOBS)
	@$(MAKE) --no-print-directory -j$(JOBS) $(foreach c,$(MODEL_CONFIGS),m/$(c).$(SEED))
	@echo "hyperram_dv: $(words $(MODEL_CONFIGS)) / $(words $(MODEL_CONFIGS)) model configurations pass"

model-seeds: $(call m_bin,$(MCFG))
	@$(MAKE) --no-print-directory -j$(JOBS) $(foreach s,$(SEEDS),m/$(MCFG).$(s))

# ------------------------------------------------------------------- lint
LINT_TOPS := hyperram_clk_model bow_hyperram_io_sim hyperram_board_model hyperram_model
lint:
	@command -v $(VERILATOR) > /dev/null 2>&1 || { echo "hyperram_dv lint: $(VERILATOR) not found"; exit 1; }
	@mkdir -p $(BUILD)
	@# warnings of the DV files only (the RTL has its own lint at the top level),
	@# every error wherever it is (e.g. an RTL file that no longer parses)
	@for m in $(LINT_TOPS) tb_hyperram_model; do \
	  $(VERILATOR) --lint-only --timing -Wall -Wno-TIMESCALEMOD --top-module $$m $(M_SRCS) 2>&1; \
	done | grep -E "^%(Warning|Error)" | grep -v -E "^%Warning[^ ]* [^ ]*bow_hyperram_pkg.sv" \
	  | grep -v "^%Error: Exiting due to" > $(BUILD)/lint.log || true
	@$(VERILATOR) --lint-only --timing -Wall -Wno-TIMESCALEMOD --top-module tb_bow_hyperram $(G_card) \
	  $(FLISTS) $(IP_SRCS) 2>&1 | grep -E "^%Error|^%Warning[^ ]* [^ ]*/hw/ip/hyperram/dv/" \
	  | grep -v "^%Error: Exiting due to" >> $(BUILD)/lint.log || true
	@if [ -s $(BUILD)/lint.log ]; then cat $(BUILD)/lint.log; echo "hyperram_dv lint: warnings / errors"; exit 1; fi
	@echo "hyperram_dv lint: OK (4 models and both testbenches, -Wall)"

# ------------------------------------------------------------- xsim (optional)
XSIM_DIR = $(BUILD)/xsim_$(1)
RTL_LIST = $(foreach f,common/common.f bus/bus.f hyperram/hyperram.f,$(addprefix \
             $(REPO)/hw/ip/$(dir $(f)),$(filter rtl/%,$(shell cat $(REPO)/hw/ip/$(f)))))
xsim:
	@rm -rf $(call XSIM_DIR,$(CFG)) && mkdir -p $(call XSIM_DIR,$(CFG))
	@cd $(call XSIM_DIR,$(CFG)) && $(XSIM_BIN)/xvlog -sv $(RTL_LIST) $(IP_SRCS) > xvlog.log 2>&1 || \
	  { grep -m10 ERROR xvlog.log; exit 1; }
	@cd $(call XSIM_DIR,$(CFG)) && $(XSIM_BIN)/xelab -debug off --timescale 1ps/1ps -s tb tb_bow_hyperram \
	  $(addprefix -generic_top ,$(X_$(call bin_of,$(CFG)))) > xelab.log 2>&1 || { grep -m10 ERROR xelab.log; exit 1; }
	@cd $(call XSIM_DIR,$(CFG)) && $(XSIM_BIN)/xsim tb -R -testplusarg SEED=$(SEED) \
	  -testplusarg hyperram_clk_seed=$(SEED) -testplusarg hyperram_board_seed=$(SEED) \
	  -testplusarg hyperram_mem_seed=$(SEED) $(addprefix -testplusarg ,$(subst +,,$(ARGS_$(CFG)) $(ARGS))) \
	  $(addprefix -testplusarg WAIVE_,$(WAIVE)) > sim.log 2>&1 || true
	@grep -q "^tb_bow_hyperram: PASS" $(call XSIM_DIR,$(CFG))/sim.log || \
	  { echo "xsim $(CFG)_s$(SEED): FAIL, see $(call XSIM_DIR,$(CFG))/sim.log"; \
	    grep -m8 -E "tb_bow_hyperram: ERROR|FAIL|ERROR" $(call XSIM_DIR,$(CFG))/sim.log; exit 1; }
	@echo "PASS xsim $(CFG)_s$(SEED) ($$(grep -m1 '^tb_bow_hyperram: PASS' $(call XSIM_DIR,$(CFG))/sim.log | sed 's/.* at //'))"

model-xsim:
	@rm -rf $(call XSIM_DIR,model_$(MCFG)) && mkdir -p $(call XSIM_DIR,model_$(MCFG))
	@cd $(call XSIM_DIR,model_$(MCFG)) && $(XSIM_BIN)/xvlog -sv $(M_SRCS) > xvlog.log 2>&1 || \
	  { tail -20 xvlog.log; exit 1; }
	@cd $(call XSIM_DIR,model_$(MCFG)) && $(XSIM_BIN)/xelab -debug off --timescale 1ps/1ps -s tb tb_hyperram_model \
	  $(addprefix -generic_top ,$(XM_$(MCFG))) > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }
	@cd $(call XSIM_DIR,model_$(MCFG)) && $(XSIM_BIN)/xsim tb -R -testplusarg SEED=$(SEED) \
	  -testplusarg hyperram_clk_seed=$(SEED) -testplusarg hyperram_board_seed=$(SEED) \
	  -testplusarg hyperram_mem_seed=$(SEED) -testplusarg hyperram_txn_log=txn.log > sim.log 2>&1 || true
	@grep -q "^tb_hyperram_model: PASS" $(call XSIM_DIR,model_$(MCFG))/sim.log || \
	  { echo "xsim model $(MCFG)_s$(SEED): FAIL, see $(call XSIM_DIR,model_$(MCFG))/sim.log"; \
	    grep -m8 -E "tb_hyperram_model: ERROR|FAIL|ERROR" $(call XSIM_DIR,model_$(MCFG))/sim.log; exit 1; }
	@echo "PASS xsim model $(MCFG)_s$(SEED) ($$(grep -m1 '^tb_hyperram_model: PASS' $(call XSIM_DIR,model_$(MCFG))/sim.log | sed 's/.* at //'))"

clean:
	rm -rf $(BUILD)

.PHONY: build build-all run case test test-ci seeds rdhold model model-build model-run model-case \
        model-seeds lint xsim model-xsim clean
SHELL := /bin/bash
