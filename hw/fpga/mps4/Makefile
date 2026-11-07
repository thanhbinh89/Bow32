# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 on the Arm MPS4 FPGA prototyping board (xcvu13p-fhga2104-1-e).
#
#   make bitstream            Vivado synthesis + implementation -> bow32_mps4.bit
#   make sdcard               + microSD card files in $(OUT)/sdcard (default goal)
#   make FLASH_VMEM=...       preload an application image into the flash
#                             (absolute path, e.g. $PWD/build/sw/hello/hello.vmem)
#   make DDR_LOOPBACK=0       DDR pads on the FMC+ DDR2 card instead of the
#                             loopback build (build only until the card exists)
#   make HR_LOOPBACK=0        HyperRAM pads on the card's S80KS2562 instead of the
#                             loopback build (default: DDR_LOOPBACK)
#   make JOBS=8               parallel Vivado jobs
#
# Loading: python3 tools/bow32_mps4.py deploy (copies $(OUT)/sdcard/MB/
# HBI0376B/BOW32 to the configuration microSD card, USB drive M1SDP, sets
# only the APPFILE line of the card's board.txt and reboots the board through
# the MCC; docs/ddr_mps4.md). The sdcard/ board.txt is only for a card of
# Bow32's own: never copy it over a shared card's board.txt. The text files
# get DOS line endings here, as the MCC requires.
# Tool: Vivado (vivado in PATH).
# Outputs: build/fpga/mps4/

REPO         := $(abspath ../../..)
OUT          := $(REPO)/build/fpga/mps4
ROM_VMEM     := $(REPO)/build/sw/bootrom/bootrom.vmem
FLASH_VMEM   ?=
VIVADO       ?= vivado
JOBS         ?= 4
DDR_LOOPBACK ?= 1
HR_LOOPBACK  ?= $(DDR_LOOPBACK)

BIT    := $(OUT)/bow32_mps4.bit
SD_DIR := $(OUT)/sdcard
SD_HBI := $(SD_DIR)/MB/HBI0376B

all: sdcard

rom:
	$(MAKE) -C $(REPO)/sw/bootrom all

bitstream: rom
	@mkdir -p $(OUT)
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log vivado.log \
	  -source $(CURDIR)/tcl/build.tcl -tclargs $(OUT) $(ROM_VMEM) "$(FLASH_VMEM)" $(JOBS) $(DDR_LOOPBACK) $(HR_LOOPBACK)

# MB/HBI0376B/board.txt points the MCC at BOW32/bow32.txt (FPGA image,
# oscillators, resets); 8.3 names, lower case files, upper case directories.
sdcard: bitstream
	rm -rf $(SD_DIR)
	@mkdir -p $(SD_HBI)/BOW32
	cp $(BIT) $(SD_HBI)/BOW32/bow32.bit
	sed 's/\r*$$/\r/' sdcard/bow32.txt > $(SD_HBI)/BOW32/bow32.txt
	sed 's/\r*$$/\r/' sdcard/board.txt > $(SD_HBI)/board.txt
	@echo "Load it with: python3 tools/bow32_mps4.py deploy   (card M1SDP; never copy $(SD_HBI)/board.txt over a shared card's own)"

clean:
	rm -rf $(OUT)

.PHONY: all rom bitstream sdcard clean
