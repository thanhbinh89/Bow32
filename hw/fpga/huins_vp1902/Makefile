# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 on the Huins MFP-VP1902-S (Versal Premium xcvp1902-vsva6865-2MP-e-S),
# with the FMC+_DDR2_HyperRam card on an FMC+ site (docs/ddr_huins.md).
#
#   make pdi                  pins + Vivado synthesis + implementation -> bow32_huins_vp1902.pdi
#                             (default goal)
#   make jtag                 load the device image over the board's USB JTAG
#                             (boot mode switch SW1 = JTAG, all levers OFF)
#   make pins                 only the pin XDC (tools/huins_pins.py)
#   make FMC_SITE=10          FMC+ site of the card, as in the board's net names
#                             (1, 10, 2, 20, 3, 30, 4, 40 for FMC+01, FMC+10, ...)
#   make CLK_SRC=ref200       clock input: ref200 = fixed 200 MHz board
#                             oscillator (the only usable one; site = the
#                             site's PL clock is refused, constr/clk_site.xdc)
#   make DDR_LOOPBACK=1       on-chip DRAM emulator behind the card's pads
#                             (shifters isolated) instead of the card's DDR2
#   make HR_LOOPBACK=1        the same for the HyperRAM (default: DDR_LOOPBACK)
#   make FLASH_VMEM=...       preload an application image into the flash
#   make JOBS=2               parallel Vivado jobs (each xcvp1902 run needs
#                             ~15 GB of memory)
#
# The Huins documents are confidential: the pins come from the board netlist
# (HUINS_DOCS, the user's local copy, gitignored) at build time and stay in
# $(OUT). Needs Vivado 2025.2 (vivado in PATH) with the xcvp1902 part, the
# MicroBlaze GCC of Vivado (PLM of the device image), Python 3 with openpyxl.
# Outputs: build/fpga/huins_vp1902/

REPO          := $(abspath ../../..)
OUT           := $(REPO)/build/fpga/huins_vp1902
ROM_VMEM      := $(REPO)/build/sw/bootrom/bootrom.vmem
FLASH_VMEM    ?=
VIVADO        ?= vivado
PYTHON        ?= python3
JOBS          ?= 2
DDR_LOOPBACK  ?= 0
HR_LOOPBACK   ?= $(DDR_LOOPBACK)
CLK_SRC       ?= ref200
FMC_SITE      ?= 10
HUINS_DOCS    ?= $(REPO)/docs/fpga/Huins_MFP-VP1902
HUINS_NETLIST ?= $(firstword $(wildcard $(HUINS_DOCS)/*NETLIST*.xlsx))
HW_SERVER     ?= localhost:3121
JTAG_SERIAL   ?=

PINS_XDC := $(OUT)/pins_fmc$(FMC_SITE)_$(CLK_SRC).xdc
PDI      := $(OUT)/bow32_huins_vp1902.pdi

all: pdi

rom:
	$(MAKE) -C $(REPO)/sw/bootrom all

pins:
	@test -n "$(HUINS_NETLIST)" || { echo "error: no Huins netlist (*NETLIST*.xlsx) in $(HUINS_DOCS): set HUINS_DOCS or HUINS_NETLIST"; exit 1; }
	@mkdir -p $(OUT)
	$(PYTHON) $(REPO)/tools/huins_pins.py --netlist "$(HUINS_NETLIST)" \
	  --pins constr/pins.txt --site $(FMC_SITE) --clk $(CLK_SRC) -o $(PINS_XDC)

pdi: rom pins
	@mkdir -p $(OUT)
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log vivado.log \
	  -source $(CURDIR)/tcl/build.tcl -tclargs $(OUT) $(ROM_VMEM) $(PINS_XDC) "$(FLASH_VMEM)" \
	  $(JOBS) $(DDR_LOOPBACK) $(HR_LOOPBACK) $(CLK_SRC)

jtag:
	@test -f $(PDI) || { echo "error: $(PDI) not found (make pdi)"; exit 1; }
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log jtag.log \
	  -source $(CURDIR)/tcl/jtag.tcl -tclargs $(PDI) $(HW_SERVER) "$(JTAG_SERIAL)"

clean:
	rm -rf $(OUT)

.PHONY: all rom pins pdi jtag clean
