# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# MKV block cipher unit test: RTL vs the reference model
# (tools/mkv/mkv_model.py), which is itself checked against every value of
# Annex A of the draft standard (`mkv_model.py selftest`).
#
#   make test                    Annex A + random keys / blocks, several seeds
#   make run SEED=7 COUNT=200    one case, files in build/mkv_dv/seed7

REPO      := $(abspath ../../../..)
BUILD     := $(REPO)/build/mkv_dv
VERILATOR ?= verilator
PYTHON    ?= python3
MODEL     := $(PYTHON) $(REPO)/tools/mkv/mkv_model.py

SEEDS ?= 1 2 3 4
SEED  ?= 1
COUNT ?= 60

SIM_BIN := $(BUILD)/obj/Vtb_bow_mkv
FLISTS  := -F $(REPO)/hw/ip/bus/bus.f -F $(REPO)/hw/ip/mkv/mkv.f
SRCS    := $(shell find $(REPO)/hw/ip/mkv $(REPO)/hw/ip/bus -name '*.sv' -o -name '*.f')

build: $(SIM_BIN)

$(SIM_BIN): $(SRCS)
	@mkdir -p $(BUILD)
	$(VERILATOR) --binary --timing -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	  --top-module tb_bow_mkv -Mdir $(BUILD)/obj -o Vtb_bow_mkv \
	  $(FLISTS) tb_bow_mkv.sv

CASE = $(BUILD)/seed$(SEED)
run: $(SIM_BIN)
	$(MODEL) selftest > /dev/null
	$(MODEL) gen $(CASE) --seed $(SEED) --count $(COUNT)
	$(SIM_BIN) +DIR=$(CASE) +SEED=$(SEED) > $(CASE)/sim.log 2>&1 || { tail -20 $(CASE)/sim.log; exit 1; }
	@grep "tb_bow_mkv:" $(CASE)/sim.log
	$(MODEL) check $(CASE)

test: $(SIM_BIN)
	@set -e; for s in $(SEEDS); do $(MAKE) --no-print-directory run SEED=$$s; done

clean:
	rm -rf $(BUILD)

.PHONY: build run test clean
