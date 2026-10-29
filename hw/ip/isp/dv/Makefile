# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# ISP unit test: RTL vs the bit-exact Python model (tools/isp/isp_model.py).
#
#   make test               random configurations, camera stream and TPG
#   make run SEED=7 TPG=1   one case, dumps in build/isp_dv/seed7_tpg
#   make test SEEDS="1 2 3 4 5 6 7 8"

REPO      := $(abspath ../../../..)
BUILD     := $(REPO)/build/isp_dv
VERILATOR ?= verilator
PYTHON    ?= python3
MODEL     := $(PYTHON) $(REPO)/tools/isp/isp_model.py

SEEDS ?= 1 2 3 4 5 6
SEED  ?= 1
TPG   ?= 0
WIDTH ?= 64
HEIGHT ?= 40

SIM_BIN := $(BUILD)/obj/Vtb_bow_isp
FLISTS  := -F $(REPO)/hw/ip/common/common.f -F $(REPO)/hw/ip/bus/bus.f -F $(REPO)/hw/ip/isp/isp.f
SRCS    := $(shell find $(REPO)/hw/ip/isp $(REPO)/hw/ip/common $(REPO)/hw/ip/bus -name '*.sv' -o -name '*.f')

build: $(SIM_BIN)

$(SIM_BIN): $(SRCS)
	@mkdir -p $(BUILD)
	$(VERILATOR) --binary --timing -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	  --top-module tb_bow_isp -Mdir $(BUILD)/obj -o Vtb_bow_isp \
	  $(FLISTS) tb_bow_isp.sv

# One case: generate, simulate, compare
CASE = $(BUILD)/seed$(SEED)$(if $(filter 1,$(TPG)),_tpg)
run: $(SIM_BIN)
	$(MODEL) gen $(CASE) --seed $(SEED) --width $(WIDTH) --height $(HEIGHT) $(if $(filter 1,$(TPG)),--tpg)
	$(SIM_BIN) +DIR=$(CASE) > $(CASE)/sim.log 2>&1 || { tail -20 $(CASE)/sim.log; exit 1; }
	$(MODEL) check $(CASE)

test: $(SIM_BIN)
	@set -e; for s in $(SEEDS); do \
	  $(MAKE) --no-print-directory run SEED=$$s TPG=0; \
	  $(MAKE) --no-print-directory run SEED=$$s TPG=1; \
	done

clean:
	rm -rf $(BUILD)

.PHONY: build run test clean
