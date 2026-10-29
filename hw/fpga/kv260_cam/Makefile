# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 + Raspberry Pi camera (MIPI CSI-2 RX) on the Kria KV260.
#
#   make bitstream            Vivado synthesis + implementation -> bow32_kv260_cam.bit
#   make firmware             + bow32_cam.bit.bin / bow32_cam.dtbo / shell.json for xmutil
#   make FLASH_VMEM=...       preload an application image into the flash
#                             (e.g. build/sw/camera/camera.vmem)
#   make jtag                 load bow32_kv260_cam.bit into a running Kria over JTAG
#                             (JTAG_SERIAL=... when several boards are connected)
#
# Tools: Vivado with the MIPI CSI-2 RX Subsystem IP (vivado, bootgen in PATH),
# dtc (device-tree-compiler), xsdb (Vitis) for `make jtag`.
# Outputs: build/fpga/kv260_cam/ (bd_ports.txt: ports of the block design)
# See docs/camera_kv260.md.

REPO       := $(abspath ../../..)
OUT        := $(REPO)/build/fpga/kv260_cam
ROM_VMEM   := $(REPO)/build/sw/bootrom/bootrom.vmem
FLASH_VMEM ?=
VIVADO     ?= vivado
BOOTGEN    ?= bootgen
DTC        ?= dtc
XSDB       ?= xsdb
JOBS       ?= 4
JTAG_SERIAL ?=

FW_DIR := $(OUT)/firmware/bow32_cam
BIT    := $(OUT)/bow32_kv260_cam.bit

all: firmware

rom:
	$(MAKE) -C $(REPO)/sw/bootrom all

bitstream: rom
	@mkdir -p $(OUT)
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log vivado.log \
	  -source $(CURDIR)/tcl/build.tcl -tclargs $(OUT) $(ROM_VMEM) "$(FLASH_VMEM)" $(JOBS)

firmware: bitstream
	@mkdir -p $(FW_DIR)
	cd $(OUT) && $(BOOTGEN) -arch zynqmp -image $(CURDIR)/overlay/bow32_cam.bif \
	  -process_bitstream bin -w on
	cp $(OUT)/bow32_kv260_cam.bit.bin $(FW_DIR)/bow32_cam.bit.bin
	cp overlay/shell.json $(FW_DIR)/shell.json
	@if command -v $(DTC) >/dev/null 2>&1; then \
	  $(DTC) -@ -O dtb -o $(FW_DIR)/bow32_cam.dtbo overlay/pl.dtsi; \
	else \
	  cp overlay/pl.dtsi $(FW_DIR)/pl.dtsi; \
	  echo "NOTE: dtc not found - compile pl.dtsi on the board: dtc -@ -O dtb -o bow32_cam.dtbo pl.dtsi"; \
	fi
	@echo "Copy $(FW_DIR) to /lib/firmware/xilinx/bow32_cam on the Kria (docs/camera_kv260.md)"

jtag:
	$(XSDB) $(CURDIR)/../kv260/tcl/jtag_load.tcl $(BIT) $(JTAG_SERIAL)

clean:
	rm -rf $(OUT)

.PHONY: all rom bitstream firmware jtag clean
