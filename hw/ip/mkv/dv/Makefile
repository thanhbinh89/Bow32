# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# MKV block cipher unit test: RTL vs the reference model
# (tools/mkv/mkv_model.py), which is itself checked against Annex A of
# TCVN 14263:2024 (`mkv_model.py selftest`).
#
#   make test                    Annex A + random keys / blocks, several seeds,
#                                then the review experiments (make review)
#   make run SEED=7 COUNT=200    one case, files in build/mkv_dv/seed7
#   make mutants [JOBS=4]        every countermeasure taken out must fail a test

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
	$(VERILATOR) --binary --timing --assert -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	  --top-module tb_bow_mkv -Mdir $(BUILD)/obj -o Vtb_bow_mkv \
	  $(FLISTS) tb_bow_mkv.sv

CASE = $(BUILD)/seed$(SEED)
run: $(SIM_BIN)
	$(MODEL) selftest > /dev/null
	$(MODEL) gen $(CASE) --seed $(SEED) --count $(COUNT)
	$(SIM_BIN) +DIR=$(CASE) +SEED=$(SEED) > $(CASE)/sim.log 2>&1 || { tail -20 $(CASE)/sim.log; exit 1; }
	@grep "tb_bow_mkv:" $(CASE)/sim.log
	$(MODEL) check $(CASE)

test: $(SIM_BIN) $(REVIEW_BIN)
	@set -e; for s in $(SEEDS); do $(MAKE) --no-print-directory run SEED=$$s; done
	@$(MAKE) --no-print-directory review

# The eight experiments of the security review (docs/mkv_security_review.md,
# section 7) as a pass / fail test of the fixes; part of `test`.
REVIEW_BIN := $(BUILD)/review/Vtb_mkv_review

$(REVIEW_BIN): $(SRCS) tb_mkv_review.sv
	@mkdir -p $(BUILD)/review
	$(VERILATOR) --binary --timing --assert -j 0 -O2 -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	  --top-module tb_mkv_review -Mdir $(BUILD)/review -o Vtb_mkv_review \
	  $(FLISTS) tb_mkv_review.sv

review: $(REVIEW_BIN)
	@$(REVIEW_BIN) > $(BUILD)/review/sim.log 2>&1 || { cat $(BUILD)/review/sim.log; exit 1; }
	@grep -E "^RESULT|tb_mkv_review:" $(BUILD)/review/sim.log

# Mutation check (not part of `test`): copies of the RTL, each without one
# countermeasure, must all fail tb_bow_mkv / tb_mkv_review (mutants.py).
JOBS ?= 4
mutants:
	$(PYTHON) mutants.py --build $(BUILD)/mutants --jobs $(JOBS)

clean:
	rm -rf $(BUILD)

.PHONY: build run test review mutants clean
