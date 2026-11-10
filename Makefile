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
	@echo "  make lint        Verilator lint of the SoC RTL (-Wall), Versal board RTL against port stubs"
	@echo "  make sim         build the Verilator testbench (KV260 and IMX274 builds)"
	@echo "  make test        run all system simulation tests, then a summary"
	@echo "  make test-tools  unit tests of the host tools (tools/tests)"
	@echo "  make test-ip     unit tests of the ISP, CSI-2 RX, H.264, MKV, DDR and HyperRAM IPs (RTL vs. models)"
	@echo "  make test-fpga-dv  pin level tests in xsim (needs Vivado): KV260 D-PHY I/O + CSI-2 RX,"
	@echo "                   DDR / HyperRAM pads + clocks, Versal clocks, Versal D-PHY (XPHY)"
	@echo "  make run TEST=x  run one test (boot|load|break|flash|irq|gpio|camera|csi2|h264|mkv|ddr|hyperram,"
	@echo "                   IMX274 build: camera274|csi2_274|video274|geo274), WAVES=1 for waves,"
	@echo "                   PLUSARGS=... testbench plusargs (e.g. +DPHY_CORNER=2), RUN_LOG=name"
	@echo "  make -C sim test-extra  optional variants of the IMX274 tests (not in make test or CI)"
	@echo "  make fpga        Vivado build, BOARD=kv260|kv260_cam|mps4|huins_vp1902 -> build/fpga/$(BOARD)/"
	@echo "                   BOARD=huins_vp1902 CARD=cam: IMX274 camera on FMC+01 -> build/fpga/huins_vp1902_cam/"
	@echo "  make fpga-jtag   load the bitstream over JTAG (Kria: xsdb; huins_vp1902: the device image,"
	@echo "                   CARD=cam for the camera build; CONFIRM=1 overrides its card / FMC+ site check)"
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

# The SoC with the default parameters (DdrEn = HrEn = 0: the KV260 build, stubs),
# with each LiteDRAM core (DDR2 at 133 MHz, DDR3 at 125 MHz CK), with HyperRAM
# (the card's pads with level shifters; the MPS4 loopback / system-simulation
# configuration: emulator of 1 MiB, together with DDR2), the CSI-2 receiver
# with 4 lanes as on the Huins camera build (FIFO 512, input delays in the
# video clock domain, 200 MHz) and with 1 lane, then two CKs that bow_ddr's
# elaboration checks must refuse (refresh interval, CK above the core's) and
# a lane count bow_csi2rx must refuse. Then the Versal board level RTL against
# port-only stubs of the AMD primitives (hw/lint/xilinx_versal_stubs.sv): the
# D-PHY with its synthetic default nibble plan, with plan 2 of its xsim test
# (inter-byte chains, 6 -> 8) and with 2 lanes on 2 nibbles, the Huins camera
# top with its clock module, and a nibble plan bow_dphy_io_versal must refuse.
LINT_CMD = $(VERILATOR) --lint-only -Wall hw/lint/verilator_waivers.vlt \
	  -F hw/top/bow32_top.f -F hw/vendor/lowrisc_ibex_prim_generic.f --top-module bow32_top
VLINT_CMD = $(VERILATOR) --lint-only -Wall hw/lint/verilator_waivers.vlt hw/lint/xilinx_versal_stubs.sv
DPHY_LINT = $(VLINT_CMD) hw/fpga/common/rtl/bow_dphy_io_versal.sv --top-module bow_dphy_io_versal

lint: deps
	$(LINT_CMD)
	$(LINT_CMD) -GDdrEn=1\'b1 -GDdrMem=2 -GDdrClkHz=133333333
	$(LINT_CMD) -GDdrEn=1\'b1 -GDdrMem=3 -GDdrClkHz=125000000
	$(LINT_CMD) -GHrEn=1\'b1
	$(LINT_CMD) -GHrEn=1\'b1 -GHrPhyKind=2 -GHrHasLs=1\'b0 -GHrEmuBytes=1048576 -GDdrEn=1\'b1
	$(LINT_CMD) -GCsiLanes=4 -GCsiFifoDepth=512 -GCsiDlyVid=1\'b1 -GVidClkHz=200000000
	$(LINT_CMD) -GCsiLanes=1
	@# the elaboration checks of bow_ddr must refuse a CK the core was not made for
	@! $(LINT_CMD) -GDdrEn=1\'b1 -GDdrMem=2 -GDdrClkHz=132000000 > /dev/null 2>&1 || \
	  { echo "lint: bow_ddr accepted the DDR2 core at 132 MHz (tREFI > 7.8 us)"; exit 1; }
	@! $(LINT_CMD) -GDdrEn=1\'b1 -GDdrMem=3 -GDdrClkHz=133333333 > /dev/null 2>&1 || \
	  { echo "lint: bow_ddr accepted the DDR3 core (125 MHz) at 133 MHz"; exit 1; }
	@# bow_csi2rx takes 1, 2 or 4 data lanes
	@! $(LINT_CMD) -GCsiLanes=3 > /dev/null 2>&1 || \
	  { echo "lint: bow_csi2rx accepted 3 data lanes"; exit 1; }
	$(DPHY_LINT)
	$(DPHY_LINT) -GNibPhys=16\'h6784 -GNibSrc=8\'h3c -GLaneNib=8\'h39 -GLaneSlice=12\'h910
	$(DPHY_LINT) -GLanes=2 -GNumNib=2 -GNibPhys=16\'h0067 -GNibRole=8\'h04 -GLaneNib=8\'h01 \
	  -GLaneSlice=12\'h020
	$(VLINT_CMD) -F hw/fpga/huins_vp1902/huins_vp1902_cam.f --top-module bow32_huins_vp1902_cam_top
	@# bow_dphy_io_versal refuses an inter-nibble receiver that is not the pair partner
	@# of its source (the strobe never reaches it)
	@! $(DPHY_LINT) -GNibPhys=16\'h2764 > /dev/null 2>&1 || \
	  { echo "lint: bow_dphy_io_versal accepted a nibble plan the strobe cannot reach"; exit 1; }
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
