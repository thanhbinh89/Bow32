# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Shared build rules for Bow32 firmware (boot ROM and applications).
#
# The including Makefile sets:
#   TARGET    output base name
#   SRCS      source files (.c / .S), any path
#   LDSCRIPT  linker script
# and may set EXTRA_CFLAGS, EXTRA_LDFLAGS, BUILD_DIR.
#
# Products: $(BUILD_DIR)/$(TARGET).{elf,bin,dis,map}

SW_ROOT   := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
REPO_ROOT := $(abspath $(SW_ROOT)/..)
BUILD_DIR ?= $(REPO_ROOT)/build/sw/$(TARGET)
PYTHON    ?= python3
IMAGE_TOOL := $(PYTHON) $(REPO_ROOT)/tools/bow32_image.py

# ---------------------------------------------------------------- toolchain
# Any bare-metal RISC-V GCC works; the first one found in PATH is used.
# Override with e.g. `make RISCV_PREFIX=riscv32-unknown-elf-`.
RISCV_PREFIX_CANDIDATES := riscv32-unknown-elf- riscv64-unknown-elf- riscv-none-elf-
ifeq ($(origin RISCV_PREFIX),undefined)
RISCV_PREFIX := $(firstword $(foreach p,$(RISCV_PREFIX_CANDIDATES),\
                  $(if $(shell command -v $(p)gcc 2>/dev/null),$(p))))
endif
ifeq ($(RISCV_PREFIX),)
$(error No RISC-V GCC found (tried $(RISCV_PREFIX_CANDIDATES)). Set RISCV_PREFIX)
endif

CC      := $(RISCV_PREFIX)gcc
OBJCOPY := $(RISCV_PREFIX)objcopy
OBJDUMP := $(RISCV_PREFIX)objdump
SIZE    := $(RISCV_PREFIX)size

# Ibex "small" configuration: RV32IMC + Zicsr
ARCH_FLAGS := -march=rv32imc_zicsr -mabi=ilp32 -mcmodel=medlow

CFLAGS := $(ARCH_FLAGS) -std=gnu11 -Os -g \
          -ffreestanding -fno-common -ffunction-sections -fdata-sections \
          -Wall -Wextra -Wno-unused-parameter \
          -I$(SW_ROOT)/common/include $(EXTRA_CFLAGS)
ASFLAGS := $(ARCH_FLAGS) -g -I$(SW_ROOT)/common/include
LDFLAGS := $(ARCH_FLAGS) -nostdlib -nostartfiles -static \
           -Wl,--gc-sections -Wl,--no-warn-rwx-segments \
           -L$(SW_ROOT)/common/link -T$(LDSCRIPT) \
           -Wl,-Map=$(BUILD_DIR)/$(TARGET).map $(EXTRA_LDFLAGS)

# --------------------------------------------------------------------- rules
ABS_SRCS := $(abspath $(SRCS))
OBJS := $(patsubst $(REPO_ROOT)/%,$(BUILD_DIR)/obj/%.o,$(ABS_SRCS))
DEPS := $(OBJS:.o=.d)

ELF := $(BUILD_DIR)/$(TARGET).elf
BIN := $(BUILD_DIR)/$(TARGET).bin
DIS := $(BUILD_DIR)/$(TARGET).dis

$(BUILD_DIR)/obj/%.c.o: $(REPO_ROOT)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -MMD -MP -c $< -o $@

$(BUILD_DIR)/obj/%.S.o: $(REPO_ROOT)/%.S
	@mkdir -p $(dir $@)
	$(CC) $(ASFLAGS) -MMD -MP -c $< -o $@

$(ELF): $(OBJS) $(LDSCRIPT)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) $(OBJS) -lgcc -o $@
	$(SIZE) $@

$(DIS): $(ELF)
	$(OBJDUMP) -d -S $< > $@

clean:
	rm -rf $(BUILD_DIR)

.PHONY: all clean
-include $(DEPS)
