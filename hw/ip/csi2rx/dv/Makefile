# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# CSI-2 receiver unit test: RTL vs the reference model (tools/csi2/csi2_model.py),
# the D-PHY side driven by csi2_tx_model.sv (lanes + receive I/O model).
#
#   make test                          random cases (SEEDS x lanes x errors) + directed tests
#   make run SEED=7 LANES=1 ERRORS=1   one random case, dumps in build/csi2rx_dv/<name>
#   make run TEST=clk                  one directed test (lp watchdog clk cmd ovf stop byteclk eye)
#   make test SEEDS="1 2 3 4 5 6 7 8"
# Options of 'run': LANES (lanes used), DUT_LANES (Lanes parameter, default LANES),
# ERRORS=1, RAW8=1, CONTCLK=1.

REPO      := $(abspath ../../../..)
BUILD     := $(REPO)/build/csi2rx_dv
VERILATOR ?= verilator
PYTHON    ?= python3
MODEL     := $(PYTHON) $(REPO)/tools/csi2/csi2_model.py

SEEDS     ?= 1 2 3 4
SEED      ?= 1
TEST      ?= random
LANES     ?= 2
DUT_LANES ?= $(LANES)
ERRORS    ?= 0
RAW8      ?= 0
CONTCLK   ?= 0
DIRECTED  := lp watchdog clk cmd ovf stop byteclk eye

sim_bin  = $(BUILD)/obj_l$(1)/Vtb_bow_csi2rx
FLISTS  := -F $(REPO)/hw/ip/common/common.f -F $(REPO)/hw/ip/bus/bus.f -F $(REPO)/hw/ip/csi2rx/csi2rx.f
SRCS    := $(shell find $(REPO)/hw/ip/csi2rx $(REPO)/hw/ip/common $(REPO)/hw/ip/bus -name '*.sv' -o -name '*.f')

build: $(call sim_bin,1) $(call sim_bin,2)

# One model per Lanes parameter
$(BUILD)/obj_l%/Vtb_bow_csi2rx: $(SRCS)
	@mkdir -p $(BUILD)
	$(VERILATOR) --binary --timing -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	  --top-module tb_bow_csi2rx -GLanes=$* -Mdir $(BUILD)/obj_l$* -o Vtb_bow_csi2rx \
	  $(FLISTS) csi2_tx_model.sv tb_bow_csi2rx.sv

# One case: generate, simulate, compare
flag = $(if $(filter 1,$($(1))),$(2))
NAME = $(TEST)$(if $(filter random,$(TEST)),_s$(SEED))_l$(LANES)$(if $(filter-out $(LANES),$(DUT_LANES)),of$(DUT_LANES))$(call flag,ERRORS,_err)$(call flag,RAW8,_raw8)$(call flag,CONTCLK,_cont)
CASE = $(BUILD)/$(NAME)
run: $(call sim_bin,$(DUT_LANES))
	@$(MODEL) gen $(CASE) --test $(TEST) --seed $(SEED) --lanes $(LANES) --dut-lanes $(DUT_LANES) \
	  $(call flag,ERRORS,--errors) $(call flag,RAW8,--raw8) $(call flag,CONTCLK,--contclk) > /dev/null
	@$(call sim_bin,$(DUT_LANES)) +DIR=$(CASE) > $(CASE)/sim.log 2>&1 || \
	  { echo "$(CASE): simulation failed"; tail -5 $(CASE)/sim.log; exit 1; }
	@$(MODEL) check $(CASE)

# Every seed: 2 lanes with and without errors, 1 lane (Lanes = 1) with errors,
# 1 lane used of 2 with and without errors; RAW8 / continuous clock alternate.
test: build
	@fail=0; for s in $(SEEDS); do \
	  r=$$((s % 2)); c=$$((s / 2 % 2)); \
	  for cfg in "2 2 0" "2 2 1" "1 1 1" "1 2 0" "1 2 1"; do \
	    set -- $$cfg; \
	    $(MAKE) --no-print-directory run TEST=random SEED=$$s LANES=$$1 DUT_LANES=$$2 \
	      ERRORS=$$3 RAW8=$$r CONTCLK=$$c || fail=1; \
	  done; \
	done; \
	for t in $(DIRECTED); do $(MAKE) --no-print-directory run TEST=$$t || fail=1; done; \
	for t in cmd stop; do $(MAKE) --no-print-directory run TEST=$$t LANES=1 || fail=1; done; \
	exit $$fail

clean:
	rm -rf $(BUILD)

.PHONY: build run test clean
