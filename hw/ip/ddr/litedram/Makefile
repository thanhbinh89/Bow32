# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Regenerate the LiteDRAM controller cores in generated/ (docs/ip/ddr.md).
# The first run creates a Python venv with the pinned packages of
# requirements.txt (network access needed once).
#
#   make            both cores: ddr2 (FMC card, MPS4 builds, system tests), ddr3 (sim)
#   make check      regenerate in a temporary directory and compare
#
# LITEX_PYTHON: Python 3.9 used to create the venv (the committed cores come from
# 3.9; Migen derives signal names from the bytecode, other versions rename signals).

REPO         := $(abspath ../../../..)
VENV         ?= $(REPO)/build/litex-venv
LITEX_PYTHON ?= python3.9
GEN          := $(VENV)/bin/python bow_ddr_litedram_gen.py
CORES        := ddr2 ddr3

all: $(CORES)

$(VENV)/.installed: requirements.txt
	$(LITEX_PYTHON) -m venv $(VENV)
	$(VENV)/bin/pip install -q --upgrade pip
	$(VENV)/bin/pip install -q -r requirements.txt
	touch $@

$(CORES): %: $(VENV)/.installed
	$(GEN) $*.yml generated/$*

check: $(VENV)/.installed
	$(foreach c,$(CORES),$(GEN) $(c).yml generated/$(c) --check &&) true

.PHONY: all check $(CORES)
