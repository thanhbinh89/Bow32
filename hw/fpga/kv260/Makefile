# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bow32 on the Kria KV260.
#
#   make bitstream            Vivado synthesis + implementation -> bow32_kv260.bit
#   make firmware             + bow32.bit.bin / bow32.dtbo / shell.json for xmutil
#   make FLASH_VMEM=...       preload an application image into the flash
#
# Tools: Vivado (vivado, bootgen in PATH), dtc (device-tree-compiler).
# Outputs: build/fpga/kv260/

REPO       := $(abspath ../../..)
OUT        := $(REPO)/build/fpga/kv260
ROM_VMEM   := $(REPO)/build/sw/bootrom/bootrom.vmem
FLASH_VMEM ?=
VIVADO     ?= vivado
BOOTGEN    ?= bootgen
DTC        ?= dtc
JOBS       ?= 4

FW_DIR := $(OUT)/firmware/bow32
BIT    := $(OUT)/bow32_kv260.bit

all: firmware

rom:
	$(MAKE) -C $(REPO)/sw/bootrom all

bitstream: rom
	@mkdir -p $(OUT)
	cd $(OUT) && $(VIVADO) -mode batch -nojournal -log vivado.log \
	  -source $(CURDIR)/tcl/build.tcl -tclargs $(OUT) $(ROM_VMEM) "$(FLASH_VMEM)" $(JOBS)

firmware: bitstream
	@mkdir -p $(FW_DIR)
	cd $(OUT) && $(BOOTGEN) -arch zynqmp -image $(CURDIR)/overlay/bow32.bif \
	  -process_bitstream bin -w on
	cp $(OUT)/bow32_kv260.bit.bin $(FW_DIR)/bow32.bit.bin
	cp overlay/shell.json $(FW_DIR)/shell.json
	@if command -v $(DTC) >/dev/null 2>&1; then \
	  $(DTC) -@ -O dtb -o $(FW_DIR)/bow32.dtbo overlay/pl.dtsi; \
	else \
	  cp overlay/pl.dtsi $(FW_DIR)/pl.dtsi; \
	  echo "NOTE: dtc not found - compile pl.dtsi on the board: dtc -@ -O dtb -o bow32.dtbo pl.dtsi"; \
	fi
	@echo "Copy $(FW_DIR) to /lib/firmware/xilinx/bow32 on the Kria (docs/fpga_kria.md)"

clean:
	rm -rf $(OUT)

.PHONY: all rom bitstream firmware clean
