# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 on the Huins MFP-VP1902-S (Versal Premium xcvp1902-vsva6865-2MP-e-S), with
# one of two cards (CARD):
#   ram  the FMC+_DDR2_HyperRam card on an FMC+ site (docs/ddr_huins.md), default
#   cam  the Leopard LI-IMX274MIPI-FMC camera on the Huins camera adapter on FMC+01
#        (Sony IMX274, MIPI CSI-2 4 lanes x 1440 Mbit/s, docs/camera_huins.md)
#
#   make pdi                  pins + Vivado synthesis + implementation -> bow32_huins_vp1902.pdi
#                             (default goal) and its build stamp pdi_site.txt (CARD, FMC_SITE)
#   make jtag                 load the device image over the board's USB JTAG
#                             (boot mode switch SW1 = JTAG, all levers OFF). Prints the
#                             stamp and the cards that must be fitted; refuses a RAM card
#                             image built for FMC+01 (FMC_SITE=1: it drives the pins the
#                             camera adapter connects to the module) and an image without
#                             a stamp or newer than it unless CONFIRM=1
#   make pins                 only the pin XDC (tools/huins_pins.py)
#   make plan CARD=cam        pins + the XPHY nibble plan of the camera pins
#                             (tcl/cam_plan.tcl, a short Vivado run, part of make pdi CARD=cam)
#   make test-plan            the plan rules of tcl/cam_plan.tcl on synthetic pin sets
#                             (tclsh, no Vivado, no board documents)
#   make test-cdc             the reviewed CDC list of the camera build
#                             (tcl/timing_checks_cam.tcl) on synthetic report rows (tclsh)
#   make CARD=cam             the camera build -> build/fpga/huins_vp1902_cam/
#                             bow32_huins_vp1902_cam.pdi (make CARD=cam jtag to load it)
#   make FMC_SITE=10          FMC+ site of the card, as in the board's net names
#                             (1, 10, 2, 20, 3, 30, 4, 40 for FMC+01, FMC+10, ...;
#                             default 10, CARD=cam: 1, the only site where the camera
#                             adapter puts every MIPI pair into one XPIO bank: another
#                             site is refused unless ANY_SITE=1)
#   make CLK_SRC=ref200       clock input: ref200 = fixed 200 MHz board
#                             oscillator (the only usable one; site = the
#                             site's PL clock is refused, constr/clk_site.xdc)
#   make DDR_LOOPBACK=1       on-chip DRAM emulator behind the card's pads
#                             (shifters isolated) instead of the card's DDR2 (CARD=ram)
#   make HR_LOOPBACK=1        the same for the HyperRAM (default: DDR_LOOPBACK)
#   make FLASH_VMEM=...       preload an application image into the flash
#   make JOBS=2               parallel Vivado jobs (each xcvp1902 run needs
#                             ~15 GB of memory)
#
# The Huins documents are confidential: the pins come from the board netlist
# (HUINS_DOCS, the user's local copy, gitignored) at build time and stay in
# $(OUT), as does the XPHY nibble plan derived from them (CARD=cam). Needs
# Vivado 2025.2 (vivado in PATH) with the xcvp1902 part, the MicroBlaze GCC
# of Vivado (PLM of the device image), Python 3 with openpyxl.
# Outputs: build/fpga/huins_vp1902/ (CARD=ram), build/fpga/huins_vp1902_cam/ (CARD=cam)

REPO          := $(abspath ../../..)
ROM_VMEM      := $(REPO)/build/sw/bootrom/bootrom.vmem
FLASH_VMEM    ?=
VIVADO        ?= vivado
PYTHON        ?= python3
JOBS          ?= 2
DDR_LOOPBACK  ?= 0
HR_LOOPBACK   ?= $(DDR_LOOPBACK)
CLK_SRC       ?= ref200
CARD          ?= ram
ANY_SITE      ?= 0
CONFIRM       ?= 0
HUINS_DOCS    ?= $(REPO)/docs/fpga/Huins_MFP-VP1902
HUINS_NETLIST ?= $(firstword $(wildcard $(HUINS_DOCS)/*NETLIST*.xlsx))
HW_SERVER     ?= localhost:3121
JTAG_SERIAL   ?=

ifeq ($(CARD),ram)
  OUT      := $(REPO)/build/fpga/huins_vp1902
  PDI_NAME := bow32_huins_vp1902.pdi
  FMC_SITE ?= 10
else ifeq ($(CARD),cam)
  OUT      := $(REPO)/build/fpga/huins_vp1902_cam
  PDI_NAME := bow32_huins_vp1902_cam.pdi
  FMC_SITE ?= 1
else
  $(error CARD must be ram or cam, not '$(CARD)')
endif

PINS_XDC := $(OUT)/pins_fmc$(FMC_SITE)_$(CLK_SRC).xdc
PLAN     := $(OUT)/pins_fmc$(FMC_SITE)_xphy_plan.txt
PDI      := $(OUT)/$(PDI_NAME)
# Build stamp next to the device image: the card and FMC+ site it was built for (make
# jtag reads it; the pins_fmc*.xdc files say nothing, several can be in $(OUT))
STAMP    := $(OUT)/pdi_site.txt

all: pdi

rom:
	$(MAKE) -C $(REPO)/sw/bootrom all

pins:
	@test -n "$(HUINS_NETLIST)" || { echo "error: no Huins netlist (*NETLIST*.xlsx) in $(HUINS_DOCS): set HUINS_DOCS or HUINS_NETLIST"; exit 1; }
	@mkdir -p $(OUT)
	$(PYTHON) $(REPO)/tools/huins_pins.py --netlist "$(HUINS_NETLIST)" \
	  --pins constr/pins.txt --card $(CARD) --site $(FMC_SITE) --clk $(CLK_SRC) \
	  $(if $(filter 1,$(ANY_SITE)),--any-site) -o $(PINS_XDC)

# XPHY nibble plan of the camera pins (board data, in $(OUT) only): bank, nibble and slice
# of every MIPI pin from the package pin functions -> the Dphy* generics of the camera top
plan: pins
ifeq ($(CARD),cam)
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log cam_plan.log \
	  -source $(CURDIR)/tcl/cam_plan.tcl -tclargs $(PINS_XDC) $(PLAN)
else
	@echo "error: only the camera build has an XPHY nibble plan (make plan CARD=cam)"; exit 1
endif

test-plan:
	tclsh tcl/cam_plan_test.tcl

test-cdc:
	tclsh tcl/timing_checks_cam_test.tcl

pdi: rom pins $(if $(filter cam,$(CARD)),plan)
	@mkdir -p $(OUT)
	@rm -f $(STAMP)
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log vivado.log \
	  -source $(CURDIR)/tcl/build.tcl -tclargs $(OUT) $(ROM_VMEM) $(PINS_XDC) "$(FLASH_VMEM)" \
	  $(JOBS) $(DDR_LOOPBACK) $(HR_LOOPBACK) $(CLK_SRC) $(CARD) $(if $(filter cam,$(CARD)),$(PLAN))
	@echo "CARD=$(CARD) FMC_SITE=$(FMC_SITE) CLK_SRC=$(CLK_SRC)$(if $(filter ram,$(CARD)), DDR_LOOPBACK=$(DDR_LOOPBACK) HR_LOOPBACK=$(HR_LOOPBACK))" > $(STAMP)
	@echo "pdi: $(PDI) for CARD=$(CARD) FMC_SITE=$(FMC_SITE) (stamp $(STAMP))"

# Board safety before loading (docs/camera_huins.md, docs/ddr_huins.md): the stamp says
# for which card and FMC+ site the image was built. A RAM card image for FMC+01 drives
# outputs into the FMC+01 pins that the camera adapter wires to the module (MIPI lanes,
# I2C, the IR-cut coil, ...), and an image without a stamp, or newer than its stamp (built
# another way, e.g. by the Makefile of another branch), is of unknown site: these need
# CONFIRM=1 after checking the fitted cards.
jtag:
	@test -f $(PDI) || { echo "error: $(PDI) not found (make pdi$(if $(filter cam,$(CARD)), CARD=cam))"; exit 1; }
	@card=; site=; refuse=; \
	if test -f $(STAMP); then \
	  echo "jtag: $(PDI_NAME) was built with $$(cat $(STAMP))"; \
	  card=$$(sed -n 's/^CARD=\([a-z]*\) .*/\1/p' $(STAMP)); \
	  site=$$(sed -n 's/.* FMC_SITE=\([0-9]*\).*/\1/p' $(STAMP)); \
	fi; \
	if test -z "$$card" || test -z "$$site"; then \
	  refuse="no build stamp $(STAMP): card and FMC+ site of the image unknown (rebuild with make pdi)"; \
	elif test "$$card" != "$(CARD)"; then \
	  refuse="the stamp says CARD=$$card, not CARD=$(CARD)"; \
	elif test $(PDI) -nt $(STAMP); then \
	  refuse="$(PDI_NAME) is newer than its stamp (not built by make pdi?): rebuild with make pdi"; \
	else \
	  fmc=$$(printf 'FMC+%02d' "$$site"); \
	  if test "$$card" = cam; then \
	    echo "jtag: fit: the Huins camera adapter + LI-IMX274MIPI-FMC on $$fmc (SW192 = 1.2 V, LED 1.2);"; \
	    echo "jtag:      the RAM card, if fitted, never on $$fmc (its site VCCIO is 1.2 V)"; \
	  else \
	    echo "jtag: fit: the FMC+_DDR2_HyperRam card on $$fmc (site VCCIO 1.5 V);"; \
	    echo "jtag:      no camera adapter on $$fmc"; \
	    if test "$$site" = 1; then \
	      refuse="a RAM card image for FMC+01 drives FMC+01 pins: never load it while the camera adapter is on FMC+01"; \
	    fi; \
	  fi; \
	fi; \
	if test -n "$$refuse"; then \
	  if test "$(CONFIRM)" = 1; then \
	    echo "jtag: CONFIRM=1, loading anyway: $$refuse"; \
	  else \
	    echo "jtag: refused: $$refuse."; \
	    echo "jtag: check the fitted cards and switches, then: make jtag CONFIRM=1$(if $(filter cam,$(CARD)), CARD=cam)"; \
	    exit 1; \
	  fi; \
	fi
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log jtag.log \
	  -source $(CURDIR)/tcl/jtag.tcl -tclargs $(PDI) $(HW_SERVER) "$(JTAG_SERIAL)"

clean:
	rm -rf $(OUT)

.PHONY: all rom pins plan test-plan test-cdc pdi jtag clean
