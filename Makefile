# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 - top level entry points. Run `make help`.

PYTHON    ?= python3
VERILATOR ?= verilator
BOARD     ?= kv260

IBEX_DIR := hw/vendor/lowrisc_ibex

.DEFAULT_GOAL := help

help:
	@echo "Bow32 - RISC-V (Ibex) learning MCU"
	@echo ""
	@echo "  make sw          build boot ROM + applications       -> build/sw/"
	@echo "  make lint        Verilator lint of the SoC RTL (-Wall)"
	@echo "  make sim         build the Verilator testbench"
	@echo "  make test        run all system simulation tests"
	@echo "  make test-tools  unit tests of the host tools (tools/tests)"
	@echo "  make run TEST=x  run one test (boot|load|break|flash|irq), WAVES=1 for waves"
	@echo "  make fpga        Vivado build for the Kria $(BOARD)     -> build/fpga/$(BOARD)/"
	@echo "  make gen         regenerate memory map files from hw/top/data/bow32_memmap.yaml"
	@echo "  make gen-check   check that generated files are up to date"
	@echo "  make clean       remove build/"

$(IBEX_DIR)/rtl/ibex_top.sv:
	git submodule update --init --recursive

deps: $(IBEX_DIR)/rtl/ibex_top.sv

sw:
	$(MAKE) -C sw all

lint: deps
	$(VERILATOR) --lint-only -Wall hw/lint/verilator_waivers.vlt \
	  -F hw/top/bow32_top.f -F hw/vendor/lowrisc_ibex_prim_generic.f --top-module bow32_top
	@echo "lint OK"

sim: deps
	$(MAKE) -C sim build

test: deps
	$(MAKE) -C sim test

test-tools:
	$(PYTHON) -m unittest discover -s tools/tests -v

run: deps
	$(MAKE) -C sim run $(if $(TEST),TEST=$(TEST)) $(if $(WAVES),WAVES=$(WAVES))

fpga: deps
	$(MAKE) -C hw/fpga/$(BOARD) all

gen:
	$(PYTHON) tools/gen_memmap.py

gen-check:
	$(PYTHON) tools/gen_memmap.py --check

clean:
	rm -rf build

.PHONY: help deps sw lint sim test test-tools run fpga gen gen-check clean
