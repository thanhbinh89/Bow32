# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Pin level test of the UltraScale+ D-PHY receive I/O (bow_dphy_io_xusp) with
# the Bow32 CSI-2 receiver, in the Vivado simulator with the unisim models
# (tb_bow_dphy_io_xusp.sv describes the stimulus and the checks).
#
#   make test                 compile, elaborate, run SEEDS
#   make test SEEDS="1 2 3 4"
#   make run SEED=5 WAVES=1   one seed, waveform database in build/fpga_dv/seed5
#
# Needs xvlog/xelab/xsim in PATH: source <Vivado>/settings64.sh first.
# Outputs: build/fpga_dv/

REPO   := $(abspath ../../../..)
BUILD  := $(REPO)/build/fpga_dv
PYTHON ?= python3
XVLOG  ?= xvlog
XELAB  ?= xelab
XSIM   ?= xsim

SEEDS ?= 1 2 3
SEED  ?= 1
WAVES ?= 0

TOP    := tb_bow_dphy_io_xusp
SNAP   := $(BUILD)/xsim.dir/$(TOP)_sim/xsimk
FLISTS := $(REPO)/hw/ip/common/common.f $(REPO)/hw/ip/bus/bus.f $(REPO)/hw/ip/csi2rx/csi2rx.f
SRCS    = $(filter %.sv %.v,$(shell cat $(BUILD)/files.txt 2>/dev/null)) $(CURDIR)/$(TOP).sv
DEBUG  := $(if $(filter 1,$(WAVES)),typical,off)

build: check-tools $(SNAP)

check-tools:
	@command -v $(XVLOG) >/dev/null 2>&1 && test -n "$$XILINX_VIVADO" || \
	  { echo "xvlog not found: source <Vivado>/settings64.sh"; exit 1; }

$(BUILD)/files.txt: $(FLISTS) flist.py
	@mkdir -p $(BUILD)
	$(PYTHON) flist.py $(FLISTS) > $@
	echo $(REPO)/hw/fpga/common/rtl/bow_dphy_io_xusp.sv >> $@

# The snapshot is rebuilt when a file list, a source or WAVES changes.
$(SNAP): $(BUILD)/files.txt $(SRCS) $(BUILD)/debug_$(DEBUG)
	cd $(BUILD) && $(XVLOG) -sv -f files.txt $(CURDIR)/$(TOP).sv > xvlog.log 2>&1 || \
	  { tail -20 xvlog.log; exit 1; }
	cd $(BUILD) && $(XVLOG) $$XILINX_VIVADO/data/verilog/src/glbl.v > xvlog_glbl.log 2>&1 || \
	  { tail -20 xvlog_glbl.log; exit 1; }
	cd $(BUILD) && $(XELAB) -L unisims_ver -L secureip -debug $(DEBUG) --timescale 1ns/1ps \
	  -s $(TOP)_sim work.$(TOP) work.glbl > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }

$(BUILD)/debug_$(DEBUG):
	@mkdir -p $(BUILD)
	rm -f $(BUILD)/debug_*
	touch $@

RUN_DIR = $(BUILD)/seed$(SEED)
run: check-tools $(SNAP)
	@mkdir -p $(RUN_DIR)
	@rm -f $(RUN_DIR)/sim.log
	@printf 'log_wave -recursive *\nrun -all\nquit\n' > $(RUN_DIR)/waves.tcl
	cd $(RUN_DIR) && $(XSIM) $(TOP)_sim --xsimdir $(BUILD)/xsim.dir -sv_seed $(SEED) -log sim.log \
	  $(if $(filter 1,$(WAVES)),-wdb $(TOP).wdb -tclbatch waves.tcl,-R) > /dev/null 2>&1 || true
	@grep -q "^$(TOP): PASS" $(RUN_DIR)/sim.log || \
	  { grep -E "ERROR|FAIL|Error" $(RUN_DIR)/sim.log | head -20; \
	    echo "$(TOP) seed $(SEED): FAIL, see $(RUN_DIR)/sim.log"; exit 1; }
	@echo "$(TOP) seed $(SEED): PASS"

test: check-tools $(SNAP)
	@set -e; for s in $(SEEDS); do $(MAKE) --no-print-directory run SEED=$$s; done

clean:
	rm -rf $(BUILD)

.PHONY: build check-tools run test clean
