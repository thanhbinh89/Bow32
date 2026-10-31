# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# H.264 encoder unit test: RTL vs the bit-exact Python model
# (tools/h264/h264_model.py).
#
#   make test                    random cases (sizes, QP 10..51, skip, deblocking)
#   make run SEED=7              one case, files in build/h264_dv/seed7
#   make run SEED=3 WIDTH=176 HEIGHT=144 FRAMES=2
#   make test SEEDS="1 2 3 4"

REPO      := $(abspath ../../../..)
BUILD     := $(REPO)/build/h264_dv
VERILATOR ?= verilator
PYTHON    ?= python3
MODEL     := $(PYTHON) $(REPO)/tools/h264/h264_model.py

SEEDS  ?= 1 2 3 4 5 6 7 8
SEED   ?= 1
WIDTH  ?= 0
HEIGHT ?= 0
FRAMES ?= 3

SIM_BIN := $(BUILD)/obj/Vtb_bow_h264
FLISTS  := -F $(REPO)/hw/ip/common/common.f -F $(REPO)/hw/ip/bus/bus.f -F $(REPO)/hw/ip/h264/h264.f
SRCS    := $(shell find $(REPO)/hw/ip/h264 $(REPO)/hw/ip/common $(REPO)/hw/ip/bus -name '*.sv' -o -name '*.f')

build: $(SIM_BIN)

$(SIM_BIN): $(SRCS)
	@mkdir -p $(BUILD)
	$(VERILATOR) --binary --timing -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	  --top-module tb_bow_h264 -Mdir $(BUILD)/obj -o Vtb_bow_h264 \
	  $(FLISTS) tb_bow_h264.sv

CASE = $(BUILD)/seed$(SEED)
run: $(SIM_BIN)
	$(MODEL) gen $(CASE) --seed $(SEED) --width $(WIDTH) --height $(HEIGHT) --frames $(FRAMES)
	$(SIM_BIN) +DIR=$(CASE) > $(CASE)/sim.log 2>&1 || { tail -20 $(CASE)/sim.log; exit 1; }
	$(MODEL) check $(CASE)

test: $(SIM_BIN)
	@set -e; for s in $(SEEDS); do $(MAKE) --no-print-directory run SEED=$$s; done

clean:
	rm -rf $(BUILD)

.PHONY: build run test clean
