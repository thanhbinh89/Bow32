# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Boot ROM. Output: build/sw/bootrom/bootrom.vmem (loaded into the ROM by
# simulation and by the FPGA build).

TARGET   := bootrom
LDSCRIPT := $(CURDIR)/bootrom.ld
ROM_SIZE := 8192

COMMON := ../common/src
SRCS := rom_start.S bootrom.c loader.c \
        $(COMMON)/bow_uart.c $(COMMON)/bow_flash.c $(COMMON)/bow_printf.c \
        $(COMMON)/bow_crc32.c $(COMMON)/bow_string.c

include ../mk/common.mk

VMEM := $(BUILD_DIR)/$(TARGET).vmem

all: $(VMEM) $(DIS)

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

$(VMEM): $(BIN)
	$(IMAGE_TOOL) vmem $< $@ --size $(ROM_SIZE) --fill 0
