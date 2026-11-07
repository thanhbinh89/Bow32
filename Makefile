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
	@echo "  make test-ip     unit tests of the ISP, CSI-2 RX, H.264, MKV and DDR IPs (RTL vs. Python models)"
	@echo "  make test-fpga-dv  pin level tests in xsim (needs Vivado): KV260 D-PHY I/O + CSI-2 RX, DDR pads + clocks"
	@echo "  make run TEST=x  run one test (boot|load|break|flash|irq|gpio|camera|csi2|h264|mkv|ddr), WAVES=1 for waves"
	@echo "  make fpga        Vivado build, BOARD=kv260|kv260_cam|mps4 -> build/fpga/$(BOARD)/"
	@echo "  make fpga-jtag   load the bitstream into a running Kria over JTAG (xsdb)"
	@echo "  make gen         regenerate memory map files from hw/top/data/bow32_memmap.yaml"
	@echo "  make gen-check   check that generated files are up to date (memory map, H.264 / MKV tables)"
	@echo "  make litedram    regenerate the LiteDRAM controller cores (Python venv in build/litex-venv)"
	@echo "  make litedram-check  check that hw/ip/ddr/litedram/generated is up to date (needs the venv)"
	@echo "  make clean       remove build/"

$(IBEX_DIR)/rtl/ibex_top.sv:
	git submodule update --init --recursive

deps: $(IBEX_DIR)/rtl/ibex_top.sv

sw:
	$(MAKE) -C sw all

# The SoC as built for simulation (DdrEn = HrEn = 0), with HyperRAM (pads, and the MPS4
# loopback configuration together with DDR2), and with each LiteDRAM core
# (DDR2 at 133 MHz, DDR3 at 125 MHz CK), then two CKs that bow_ddr's
# elaboration checks must refuse (refresh interval, CK above the core's).
LINT_CMD = $(VERILATOR) --lint-only -Wall hw/lint/verilator_waivers.vlt \
	  -F hw/top/bow32_top.f -F hw/vendor/lowrisc_ibex_prim_generic.f --top-module bow32_top

lint: deps
	$(LINT_CMD)
	$(LINT_CMD) -GDdrEn=1\'b1 -GDdrMem=2 -GDdrClkHz=133333333
	$(LINT_CMD) -GDdrEn=1\'b1 -GDdrMem=3 -GDdrClkHz=125000000
	$(LINT_CMD) -GHrEn=1\'b1
	$(LINT_CMD) -GHrEn=1\'b1 -GHrPhyKind=2 -GHrHasLs=1\'b0 -GHrEmuBytes=4194304 -GDdrEn=1\'b1
	@# the elaboration checks of bow_ddr must refuse a CK the core was not made for
	@! $(LINT_CMD) -GDdrEn=1\'b1 -GDdrMem=2 -GDdrClkHz=132000000 > /dev/null 2>&1 || \
	  { echo "lint: bow_ddr accepted the DDR2 core at 132 MHz (tREFI > 7.8 us)"; exit 1; }
	@! $(LINT_CMD) -GDdrEn=1\'b1 -GDdrMem=3 -GDdrClkHz=133333333 > /dev/null 2>&1 || \
	  { echo "lint: bow_ddr accepted the DDR3 core (125 MHz) at 133 MHz"; exit 1; }
	@echo "lint OK"

sim: deps
	$(MAKE) -C sim build

test: deps
	$(MAKE) -C sim test

test-tools:
	$(PYTHON) -m unittest discover -s tools/tests -v

test-ip:
	$(MAKE) -C hw/ip/isp/dv test
	$(MAKE) -C hw/ip/csi2rx/dv test
	$(MAKE) -C hw/ip/h264/dv test
	$(MAKE) -C hw/ip/mkv/dv test
	$(MAKE) -C hw/ip/ddr/dv test
	$(MAKE) -C hw/ip/hyperram/dv test

test-fpga-dv:
	$(MAKE) -C hw/fpga/common/dv test

run: deps
	$(MAKE) -C sim run $(if $(TEST),TEST=$(TEST)) $(if $(WAVES),WAVES=$(WAVES))

fpga: deps
	$(MAKE) -C hw/fpga/$(BOARD) all

fpga-jtag:
	$(MAKE) -C hw/fpga/$(BOARD) jtag

gen:
	$(PYTHON) tools/gen_memmap.py
	$(PYTHON) tools/h264/h264_model.py tables
	$(PYTHON) tools/mkv/mkv_model.py tables

gen-check:
	$(PYTHON) tools/gen_memmap.py --check
	$(PYTHON) tools/h264/h264_model.py tables --check
	$(PYTHON) tools/mkv/mkv_model.py tables --check

litedram:
	$(MAKE) -C hw/ip/ddr/litedram all

litedram-check:
	$(MAKE) -C hw/ip/ddr/litedram check

clean:
	rm -rf build

.PHONY: help deps sw lint sim test test-tools test-ip test-fpga-dv run fpga fpga-jtag gen gen-check litedram litedram-check clean
