# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Build an application that runs from the internal flash.
#
# Minimal application Makefile:
#   APP  := hello
#   SRCS := main.c
#   include ../../mk/app.mk
#
# Products in build/sw/<app>/:
#   <app>.elf   debug symbols
#   <app>.bin   flash image with header (flash with tools/bow32_flash.py)
#   <app>.vmem  same image for simulation ($readmemh)
#   <app>.dis   disassembly

TARGET   := $(APP)
_APP_MK_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
LDSCRIPT ?= $(_APP_MK_DIR)/../common/link/app_flash.ld

SRCS += $(_APP_MK_DIR)/../common/startup/crt0.S \
        $(wildcard $(_APP_MK_DIR)/../common/src/*.c)

include $(_APP_MK_DIR)/common.mk

VMEM := $(BUILD_DIR)/$(TARGET).vmem

all: $(BIN) $(VMEM) $(DIS)

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@
	$(IMAGE_TOOL) patch $@

$(VMEM): $(BIN)
	$(IMAGE_TOOL) vmem $< $@
