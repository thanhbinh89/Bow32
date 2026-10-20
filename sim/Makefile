# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# System simulation with Verilator (>= 5.0, uses --binary --timing).
#
#   make build                 compile the testbench
#   make run TEST=boot         run one test (boot | load | break | flash | irq)
#   make test                  run all tests
#   make run TEST=load WAVES=1 also dump build/sim/waves.fst (open with GTKWave)

REPO      := $(abspath ..)
BUILD     := $(REPO)/build/sim
SW_BUILD  := $(REPO)/build/sw
VERILATOR ?= verilator
WAVES     ?= 0

TEST  ?= boot
TESTS := boot load break flash irq

ROM_VMEM := $(SW_BUILD)/bootrom/bootrom.vmem

# Firmware used by each test
FLASH_boot  := $(SW_BUILD)/hello/hello.vmem
FLASH_break := $(SW_BUILD)/hello/hello.vmem
FLASH_flash := $(SW_BUILD)/flash_demo/flash_demo.vmem
FLASH_irq   := $(SW_BUILD)/uart_irq/uart_irq.vmem
IMAGE_load  := $(SW_BUILD)/hello/hello.vmem

# Separate model directories with and without waveform tracing.
OBJ_DIR := $(BUILD)/obj$(if $(filter 1,$(WAVES)),-waves)

RTL_FLISTS := -F $(REPO)/hw/top/bow32_top.f -F $(REPO)/hw/vendor/lowrisc_ibex_prim_generic.f
VFLAGS := --binary --timing -j 0 -O2 --x-assign fast --x-initial fast \
          -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
          --top-module tb_bow32 -Mdir $(OBJ_DIR) -o Vtb_bow32
ifeq ($(WAVES),1)
VFLAGS += --trace-fst --trace-structs
endif

SIM_BIN := $(OBJ_DIR)/Vtb_bow32
TB_SRCS := tb/tb_bow32.sv
RTL_DEPS := $(shell find $(REPO)/hw/ip $(REPO)/hw/top -name '*.sv' -o -name '*.f')

build: $(SIM_BIN)

$(SIM_BIN): $(TB_SRCS) $(RTL_DEPS)
	@mkdir -p $(BUILD)
	$(VERILATOR) $(VFLAGS) $(REPO)/hw/lint/verilator_waivers.vlt $(RTL_FLISTS) $(TB_SRCS)

sw:
	$(MAKE) -C $(REPO)/sw all

run: $(SIM_BIN) sw
	cd $(BUILD) && $(SIM_BIN) +TEST=$(TEST) +ROM=$(ROM_VMEM) \
	  $(if $(FLASH_$(TEST)),+FLASH=$(FLASH_$(TEST))) \
	  $(if $(IMAGE_$(TEST)),+IMAGE=$(IMAGE_$(TEST))) \
	  $(if $(filter 1,$(WAVES)),+WAVES) | tee $(BUILD)/$(TEST).log
	@grep -q "TEST PASSED" $(BUILD)/$(TEST).log

test: $(SIM_BIN) sw
	@set -e; for t in $(TESTS); do \
	  $(MAKE) --no-print-directory run TEST=$$t > /dev/null 2>&1 \
	    && echo "PASS  $$t" || { echo "FAIL  $$t (see build/sim/$$t.log)"; exit 1; }; \
	done

clean:
	rm -rf $(BUILD)

.PHONY: build run test sw clean
