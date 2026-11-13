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
	@echo "  make lint        Verilator lint of the SoC RTL (-Wall), the board tops and AFE adapters against port stubs"
	@echo "  make sim         build the Verilator testbench (KV260 and IMX274 builds)"
	@echo "  make test        run all system simulation tests, then a summary"
	@echo "  make test-tools  unit tests of the host tools (tools/tests)"
	@echo "  make test-ip     unit tests of the ISP, CSI-2 RX, D-PHY RX, H.264, MKV, DDR and HyperRAM IPs (RTL vs. models)"
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

# The SoC with the default parameters (DdrEn = HrEn = 0: the KV260 build, stubs;
# CsiByteClkHz, which has no default, = the default video clock of 50 MHz),
# with each LiteDRAM core (DDR2 at 133 MHz, DDR3 at 125 MHz CK), with HyperRAM
# (the card's pads with level shifters; the MPS4 loopback / system-simulation
# configuration: emulator of 1 MiB, together with DDR2), the CSI-2 receiver
# with 4 lanes as on the Huins camera build (FIFO 512, the Versal AFE kind,
# 200 MHz, byte clock 180 MHz) and with 1 lane, then two CKs that bow_ddr's
# elaboration checks must refuse (refresh interval, CK above the core's),
# a lane count bow_mipi_rx must refuse, and the byte clocks bow32_top must
# refuse with the controller's message (SOC_BAD below: none, one above the
# video clock). The receiver on its own (bow_mipi_rx:
# 2, 1 and 4 lanes as on the KV260, Huins and 1 lane builds, without a PHY;
# none and a byte clock above its video clock it must refuse), its CSI-2 controller on
# its own with the PPI ports (bow_csi2rx: the same configurations, each
# stating the PHY's lp clock and highest byte clock; no lp clock, one above
# 32 x its clock csi_clk_i, no byte clock or one above csi_clk_i, step 7 of
# docs/ip/mipi_rx_arch.md, it must refuse, with its own message), the controller
# with flat PPI ports for a standard PHY (bow_csi2rx_ppi_flat, not in
# csi2rx.f: 2, 1 and 4 lanes, 50 MHz video clock; no byte clock it must refuse) and its digital
# D-PHY on its own (bow_dphy_rx with its whole AFE interface: 1, 2 and 4 lanes,
# the UltraScale+ and the Versal AFE kind, an ASIC configuration with the AFE
# powered down after reset and 32 trim bits; a lane count it must refuse).
# Then the board level RTL against port-only stubs of the AMD primitives
# (hw/lint/xilinx_versal_stubs.sv, with hw/lint/xilinx_xusp_stubs.sv for
# UltraScale+): the AFE adapters' logic without primitives on its own
# (bow_dphy_dly_xusp, bow_dphy_dly_xphy: 1, 2 and 4 lanes), the UltraScale+
# AFE adapter (bow_dphy_io_xusp: 1, 2 and 4 lanes), the Versal one with its
# synthetic default nibble plan, with plan 2 of its xsim test (inter-byte
# chains, 6 -> 8) and with 2 lanes on 2 nibbles, a nibble plan
# bow_dphy_io_versal must refuse, and every board top with bow32_top (step 5
# of docs/ip/mipi_rx_arch.md): KV260 and KV260 camera (with port-only stubs of
# their block design wrappers, hw/lint/kv260_bd_stubs.sv), MPS4, Huins RAM
# card and Huins camera with its clock module; the sixth user of bow32_top, the
# system testbench sim/tb/tb_bow32.sv, its pin connections only (make -C sim
# lint, both builds: a pin missing from an instance is an error, and so is an
# input connected to nothing, .pin (), which hw/lint/empty_inputs.py finds in
# Verilator's netlist; an empty output is a normal no-connect).
LINT_CMD = $(VERILATOR) --lint-only -Wall hw/lint/verilator_waivers.vlt \
	  -F hw/top/bow32_top.f -F hw/vendor/lowrisc_ibex_prim_generic.f --top-module bow32_top
DPHYRX_LINT = $(VERILATOR) --lint-only -Wall hw/lint/verilator_waivers.vlt \
	  -F hw/ip/common/common.f -F hw/ip/bus/bus.f -F hw/ip/dphy_rx/dphy_rx.f --top-module bow_dphy_rx
RX_LINT = $(VERILATOR) --lint-only -Wall hw/lint/verilator_waivers.vlt -F hw/ip/common/common.f \
	  -F hw/ip/bus/bus.f -F hw/ip/dphy_rx/dphy_rx.f -F hw/ip/csi2rx/csi2rx.f
RX_CFGS = "-GByteClkHz=114000000" "-GLanes=1 -GByteClkHz=114000000" \
	  "-GLanes=4 -GAfeKind=2 -GFifoDepth=512 -GByteClkHz=180000000" \
	  "-GHasPhy=1'b0 -GPhyClkHz=50000000 -GByteClkHz=50000000"
# the controller alone: the same, with the PHY's lp clock and highest byte clock = its clock
# csi_clk_i (PhyClkHz, 200 MHz default), once with an lp clock of 32 x its clock (the PPI
# error counters' limit) and once with a byte clock below it (180 MHz: the Huins camera)
CTRL_CFGS = "-GPpiLpClkHz=200000000 -GPpiByteClkHz=200000000" \
	  "-GLanes=1 -GPpiLpClkHz=200000000 -GPpiByteClkHz=200000000" \
	  "-GLanes=4 -GFifoDepth=512 -GPpiLpClkHz=200000000 -GPpiByteClkHz=180000000" \
	  "-GHasPhy=1'b0 -GPhyClkHz=50000000 -GPpiLpClkHz=50000000 -GPpiByteClkHz=50000000 -GDphyWin=1'b0" \
	  "-GPhyClkHz=50000000 -GPpiLpClkHz=1600000000 -GPpiByteClkHz=50000000"
# arguments for bow_csi2rx alone that it must refuse, and the message it must refuse them with
CTRL_BAD = "-GPpiByteClkHz=200000000|PpiLpClkHz not set" \
	  "-GPhyClkHz=50000000 -GPpiLpClkHz=1700000000 -GPpiByteClkHz=50000000|PPI lp clock 1700000000 Hz > 32 x csi_clk_i" \
	  "-GPpiLpClkHz=200000000|PpiByteClkHz not set" \
	  "-GPpiLpClkHz=200000000 -GPpiByteClkHz=200000001|PPI byte clock 200000001 Hz > csi_clk_i 200000000 Hz"
# arguments for the SoC (bow32_top) that it must refuse, and the message (review of step 7):
# no CsiByteClkHz (no default), a byte clock above the video clock (the KV260 camera's 114 MHz
# with the 107.5 MHz video clock of its system simulation up to that review; the Huins
# camera's configuration with 200 000 001 Hz)
SOC_BAD = "-GCsiLanes=2|bow32_top: CsiByteClkHz not set" \
	  "-GVidClkHz=107526882 -GCsiByteClkHz=114000000|PPI byte clock 114000000 Hz > csi_clk_i 107526882 Hz" \
	  "-GCsiLanes=4 -GCsiFifoDepth=512 -GCsiAfeKind=2 -GVidClkHz=200000000 -GCsiByteClkHz=200000001|PPI byte clock 200000001 Hz > csi_clk_i 200000000 Hz"
# the flat-port wrapper of the controller (standard PHY)
FLAT_LINT = $(RX_LINT) hw/ip/csi2rx/rtl/bow_csi2rx_ppi_flat.sv --top-module bow_csi2rx_ppi_flat
FLAT_CFGS = "-GByteClkHz=180000000" "-GLanes=1 -GByteClkHz=180000000" \
	  "-GLanes=4 -GFifoDepth=512 -GByteClkHz=180000000" "-GPhyClkHz=50000000 -GByteClkHz=50000000"
VLINT_CMD = $(VERILATOR) --lint-only -Wall hw/lint/verilator_waivers.vlt hw/lint/xilinx_versal_stubs.sv
XLINT_CMD = $(VLINT_CMD) hw/lint/xilinx_xusp_stubs.sv
DPHY_LINT = $(VLINT_CMD) -F hw/ip/common/common.f hw/fpga/common/rtl/bow_dphy_dly_xphy.sv \
	  hw/fpga/common/rtl/bow_dphy_io_versal.sv --top-module bow_dphy_io_versal
XDPHY_LINT = $(XLINT_CMD) -F hw/ip/common/common.f hw/fpga/common/rtl/bow_dphy_dly_xusp.sv \
	  hw/fpga/common/rtl/bow_dphy_io_xusp.sv --top-module bow_dphy_io_xusp
DLY_LINT = $(VERILATOR) --lint-only -Wall hw/lint/verilator_waivers.vlt -F hw/ip/common/common.f
# the board tops (the file lists of their FPGA builds) against the stubs
TOP_LINT = $(XLINT_CMD) hw/lint/kv260_bd_stubs.sv
TOP_LINT_BOARDS = kv260/kv260.f:bow32_kv260_top kv260_cam/kv260_cam.f:bow32_kv260_cam_top \
	  mps4/mps4.f:bow32_mps4_top huins_vp1902/huins_vp1902.f:bow32_huins_vp1902_top \
	  huins_vp1902/huins_vp1902_cam.f:bow32_huins_vp1902_cam_top

lint: deps
	$(LINT_CMD) -GCsiByteClkHz=50000000
	$(LINT_CMD) -GCsiByteClkHz=50000000 -GDdrEn=1\'b1 -GDdrMem=2 -GDdrClkHz=133333333
	$(LINT_CMD) -GCsiByteClkHz=50000000 -GDdrEn=1\'b1 -GDdrMem=3 -GDdrClkHz=125000000
	$(LINT_CMD) -GCsiByteClkHz=50000000 -GHrEn=1\'b1
	$(LINT_CMD) -GCsiByteClkHz=50000000 -GHrEn=1\'b1 -GHrPhyKind=2 -GHrHasLs=1\'b0 \
	  -GHrEmuBytes=1048576 -GDdrEn=1\'b1
	$(LINT_CMD) -GCsiLanes=4 -GCsiFifoDepth=512 -GCsiAfeKind=2 -GVidClkHz=200000000 \
	  -GCsiByteClkHz=180000000
	$(LINT_CMD) -GCsiLanes=1 -GCsiByteClkHz=50000000
	@# the elaboration checks of bow_ddr must refuse a CK the core was not made for
	@! $(LINT_CMD) -GCsiByteClkHz=50000000 -GDdrEn=1\'b1 -GDdrMem=2 -GDdrClkHz=132000000 \
	  > /dev/null 2>&1 || \
	  { echo "lint: bow_ddr accepted the DDR2 core at 132 MHz (tREFI > 7.8 us)"; exit 1; }
	@! $(LINT_CMD) -GCsiByteClkHz=50000000 -GDdrEn=1\'b1 -GDdrMem=3 -GDdrClkHz=133333333 \
	  > /dev/null 2>&1 || \
	  { echo "lint: bow_ddr accepted the DDR3 core (125 MHz) at 133 MHz"; exit 1; }
	@# bow_mipi_rx takes 1, 2 or 4 data lanes
	@! $(LINT_CMD) -GCsiByteClkHz=50000000 -GCsiLanes=3 > /dev/null 2>&1 || \
	  { echo "lint: bow_mipi_rx accepted 3 data lanes"; exit 1; }
	@# the byte clock rule in the SoC (review of step 7 of docs/ip/mipi_rx_arch.md): every
	@# build states CsiByteClkHz, and it reaches the controller's check
	@for c in $(SOC_BAD); do g="$${c%%|*}"; m="$${c#*|}"; \
	  if out="$$($(LINT_CMD) $$g 2>&1)"; then \
	    echo "lint: bow32_top accepted '$$g' (expected: $$m)"; exit 1; fi; \
	  echo "$$out" | grep -q "$$m" || { echo "lint: bow32_top refused '$$g' without '$$m':"; \
	    echo "$$out" | head -5; exit 1; }; done
	@for g in $(RX_CFGS); do echo "$(RX_LINT) --top-module bow_mipi_rx $$g"; \
	  $(RX_LINT) --top-module bow_mipi_rx $$g || exit 1; done
	@# bow_mipi_rx (step 7): a byte clock above vid_clk_i (the controller's clock) is refused,
	@# and so is none (no default since the review of step 7)
	@out=$$($(RX_LINT) --top-module bow_mipi_rx -GByteClkHz=250000000 2>&1) && \
	  { echo "lint: bow_mipi_rx accepted a 250 MHz byte clock with a 200 MHz video clock"; exit 1; }; \
	  echo "$$out" | grep -q "PPI byte clock 250000000 Hz > csi_clk_i 200000000 Hz" || \
	  { echo "lint: bow_mipi_rx refused 250 MHz without the clock message:"; echo "$$out"; exit 1; }
	@out=$$($(RX_LINT) --top-module bow_mipi_rx 2>&1) && \
	  { echo "lint: bow_mipi_rx accepted no ByteClkHz"; exit 1; }; \
	  echo "$$out" | grep -q "bow_mipi_rx: ByteClkHz not set" || \
	  { echo "lint: bow_mipi_rx refused no ByteClkHz without its message:"; echo "$$out"; exit 1; }
	@for g in $(CTRL_CFGS); do echo "$(RX_LINT) --top-module bow_csi2rx $$g"; \
	  $(RX_LINT) --top-module bow_csi2rx $$g || exit 1; done
	@# bow_csi2rx: the PPI lp errors are gray counters of the PHY's lp clock, sampled on its
	@# clock csi_clk_i (at least lp / 32), its lane merge FIFO needs csi_clk_i >= the byte
	@# clock (step 7), and every instantiation states both clocks (no defaults)
	@for c in $(CTRL_BAD); do g="$${c%%|*}"; m="$${c#*|}"; \
	  if out="$$($(RX_LINT) --top-module bow_csi2rx $$g 2>&1)"; then \
	    echo "lint: bow_csi2rx accepted '$$g' (expected: $$m)"; exit 1; fi; \
	  echo "$$out" | grep -q "$$m" || { echo "lint: bow_csi2rx refused '$$g' without '$$m':"; \
	    echo "$$out" | head -5; exit 1; }; done
	@for g in $(FLAT_CFGS); do echo "$(FLAT_LINT) $$g"; $(FLAT_LINT) $$g || exit 1; done
	@out=$$($(FLAT_LINT) 2>&1) && { echo "lint: bow_csi2rx_ppi_flat accepted no ByteClkHz"; exit 1; }; \
	  echo "$$out" | grep -q "bow_csi2rx_ppi_flat: ByteClkHz not set" || \
	  { echo "lint: bow_csi2rx_ppi_flat refused no ByteClkHz without its message:"; \
	    echo "$$out"; exit 1; }
	$(DPHYRX_LINT)
	$(DPHYRX_LINT) -GLanes=1
	$(DPHYRX_LINT) -GLanes=4 -GAfeKind=2
	$(DPHYRX_LINT) -GLanes=2 -GAfeKind=2
	$(DPHYRX_LINT) -GLanes=4 -GAfeKind=0 -GAfePdRst=1\'b1 -GTrimW=32
	@! $(DPHYRX_LINT) -GLanes=3 > /dev/null 2>&1 || \
	  { echo "lint: bow_dphy_rx accepted 3 data lanes"; exit 1; }
	@# bow_dphy_rx (step 6): the gray event counters need lp_clk_i <= 12 x clk_i
	$(DPHYRX_LINT) -GLpClkHz=600000000 -GBusClkHz=50000000
	@out=$$($(DPHYRX_LINT) -GLpClkHz=650000000 -GBusClkHz=50000000 2>&1) && \
	  { echo "lint: bow_dphy_rx accepted a 650 MHz lp clock with a 50 MHz CPU clock"; exit 1; }; \
	  echo "$$out" | grep -q "lp_clk_i 650000000 Hz > 12 x clk_i" || \
	  { echo "lint: bow_dphy_rx refused 650 MHz without the clock message:"; echo "$$out"; exit 1; }
	@for g in "-GLanes=1" "-GLanes=2" "-GLanes=4"; do \
	  for m in bow_dphy_dly_xusp bow_dphy_dly_xphy; do \
	    echo "$(DLY_LINT) hw/fpga/common/rtl/$$m.sv --top-module $$m $$g"; \
	    $(DLY_LINT) hw/fpga/common/rtl/$$m.sv --top-module $$m $$g || exit 1; done; \
	  echo "$(XDPHY_LINT) $$g"; $(XDPHY_LINT) $$g || exit 1; done
	$(DPHY_LINT)
	$(DPHY_LINT) -GNibPhys=16\'h6784 -GNibSrc=8\'h3c -GLaneNib=8\'h39 -GLaneSlice=12\'h910
	$(DPHY_LINT) -GLanes=2 -GNumNib=2 -GNibPhys=16\'h0067 -GNibRole=8\'h04 -GLaneNib=8\'h01 \
	  -GLaneSlice=12\'h020
	@for b in $(TOP_LINT_BOARDS); do f="$${b%%:*}"; t="$${b#*:}"; \
	  echo "$(TOP_LINT) -F hw/fpga/$$f --top-module $$t"; \
	  $(TOP_LINT) -F hw/fpga/$$f --top-module $$t || exit 1; done
	$(MAKE) --no-print-directory -C sim lint
	@# bow_dphy_io_versal refuses an inter-nibble receiver that is not the pair partner
	@# of its source (the strobe never reaches it)
	@! $(DPHY_LINT) -GNibPhys=16\'h2764 > /dev/null 2>&1 || \
	  { echo "lint: bow_dphy_io_versal accepted a nibble plan the strobe cannot reach"; exit 1; }
	@# bow_csi2rx (in bow_mipi_rx): LP event pulses need vid_clk_i <= 16/3 x clk_i
	@out=$$($(LINT_CMD) -GVidClkHz=300000000 -GCsiByteClkHz=200000000 2>&1) && \
	  { echo "lint: bow_csi2rx accepted a 300 MHz video clock with a 50 MHz CPU clock"; exit 1; }; \
	  echo "$$out" | grep -q "csi_clk_i 300000000 Hz > 16/3 x clk_i 50000000 Hz" || \
	  { echo "lint: bow_csi2rx refused 300 MHz without the clock message:"; echo "$$out"; exit 1; }
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
	$(MAKE) -C hw/ip/dphy_rx/dv test
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
