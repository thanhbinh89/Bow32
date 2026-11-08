# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Pin level tests of the UltraScale+ I/O and clock wrappers in the Vivado
# simulator with the unisim models (each testbench describes its stimulus and
# its checks):
#   tb_bow_dphy_io_xusp   KV260 D-PHY receive I/O (bow_dphy_io_xusp) + bow_csi2rx
#   tb_bow_ddr_io_xilinx  DDR2/DDR3 pads (bow_ddr_io_xilinx) on bow_ddr_clk_xusp,
#                         configurations DDR_IO_CFGS (below)
#   tb_bow_ddr_clk_xusp   DDR clocks (bow_ddr_clk_xusp: three MMCME4_ADV, fine
#                         phase shift, LiteDRAM controller clock CK / 4),
#                         configurations DDR_CLK_CFGS
#   tb_bow_hyperram_io_xilinx  HyperRAM pads (bow_hyperram_io_xilinx) on their
#                         clocks (bow_hyperram_clk_xusp: two MMCME4_ADV, fine
#                         phase shift of the write and read clocks, lock-loss
#                         reset), configurations HR_IO_CFGS
#
#   make test                 all of them: D-PHY, DDR and HyperRAM pads with every
#                             seed of SEEDS, DDR clocks once per configuration
#   make test SEEDS="1 2 3 4"
#   make run SEED=5 WAVES=1   D-PHY, one seed, waveform database in build/fpga_dv/seed5
#   make test-dphy | test-ddr-io | test-ddr-clk | test-hr-io     one testbench
#   make run-ddr-io IO_CFG=lb SEED=2 WAVES=1        one pad configuration and seed,
#                                                   files in build/fpga_dv/ddr_io/lb/seed2
#   make run-ddr-clk CLK_CFG=125 WAVES=1            one clock configuration,
#                                                   files in build/fpga_dv/ddr_clk/125/run
#   make run-hr-io HR_IO_CFG=lb SEED=2 WAVES=1      one HyperRAM configuration and seed,
#                                                   files in build/fpga_dv/hr_io/lb/seed2
#   make mutants              not part of test: broken copies of the DDR and HyperRAM
#                             pad / clock wrappers (mutants.py), each one must FAIL
#
# Needs xvlog/xelab/xsim in PATH: source <Vivado>/settings64.sh first. The
# exit code of xsim does not reflect the result: pass/fail comes from the
# "<testbench>: PASS" line of sim.log.
# Outputs: build/fpga_dv/ (D-PHY), build/fpga_dv/ddr_io/<cfg>/,
# build/fpga_dv/ddr_clk/<cfg>/, build/fpga_dv/hr_io/<cfg>/,
# build/fpga_dv/mutants/<name>/: one xsim library and snapshot directory
# (xsim.dir) each.

REPO   := $(abspath ../../../..)
BUILD  := $(REPO)/build/fpga_dv
PYTHON ?= python3
XVLOG  ?= xvlog
XELAB  ?= xelab
XSIM   ?= xsim

SEEDS ?= 1 2 3
SEED  ?= 1
WAVES ?= 0

DEBUG  := $(if $(filter 1,$(WAVES)),typical,off)
XELAB_OPTS = -L unisims_ver -L secureip -debug $(DEBUG) --timescale 1ns/1ps
GLBL   = $$XILINX_VIVADO/data/verilog/src/glbl.v

# ------------------------------------------------------------- D-PHY I/O
TOP    := tb_bow_dphy_io_xusp
SNAP   := $(BUILD)/xsim.dir/$(TOP)_sim/xsimk
FLISTS := $(REPO)/hw/ip/common/common.f $(REPO)/hw/ip/bus/bus.f $(REPO)/hw/ip/csi2rx/csi2rx.f
SRCS    = $(filter %.sv %.v,$(shell cat $(BUILD)/files.txt 2>/dev/null)) $(CURDIR)/$(TOP).sv

# --------------------------------------------------------------- DDR pads
# Configurations of bow_ddr_io_xilinx (xelab -generic_top of the testbench):
#   card  x8, level shifter pins, CK as two single ended outputs, DIR read
#         level 1: the MPS4 FMC+ DDR2 card
#   x16   x16 with DM and RESET#, 16 address / 3 bank pins, CK on OBUFDS, DIR
#         read level 0
#   lb    x8 loopback (the MPS4 loopback build: bow_ddr_lb behind the pads)
#   lb16  x16 loopback with DM, no level shifter pins
DDR_IO_TOP   := tb_bow_ddr_io_xilinx
DDR_IO_DIR   ?= $(BUILD)/ddr_io
DDR_IO_RTL   ?= $(REPO)/hw/fpga/common/rtl/bow_ddr_io_xilinx.sv
DDR_CLK_RTL  ?= $(REPO)/hw/fpga/common/rtl/bow_ddr_clk_xusp.sv
DDR_IO_SRCS   = $(REPO)/hw/ip/ddr/rtl/bow_ddr_pkg.sv $(DDR_CLK_RTL) $(DDR_IO_RTL) \
                $(CURDIR)/$(DDR_IO_TOP).sv
DDR_IO_CFGS  ?= card x16 lb lb16
DDR_IO_GEN_card :=
DDR_IO_GEN_x16  := DqBits=16 AddrPins=16 BankPins=3 HasDm=1 HasResetN=1 CkSingleEnded=0 \
                   LsDirReadLevel=0
DDR_IO_GEN_lb   := Loopback=1
DDR_IO_GEN_lb16 := DqBits=16 HasDm=1 HasLs=0 Loopback=1
IO_CFG ?= card
ddr_io_snap = $(DDR_IO_DIR)/$(1)/xsim.dir/$(DDR_IO_TOP)_sim/xsimk

# ------------------------------------------------------------- DDR clocks
# Configurations of bow_ddr_clk_xusp: 133 = MPS4 (VCO 1200 MHz, DDR /9, 504
# phase steps), 125 = the DDR3 simulation clock (VCO 1000 MHz, /8, 448 steps).
DDR_CLK_TOP  := tb_bow_ddr_clk_xusp
DDR_CLK_DIR  ?= $(BUILD)/ddr_clk
DDR_CLK_SRCS  = $(DDR_CLK_RTL) $(CURDIR)/$(DDR_CLK_TOP).sv
DDR_CLK_CFGS ?= 133 125
DDR_CLK_GEN_133 :=
DDR_CLK_GEN_125 := T=8.0 STEPS=448 VcoMult=10.0 DdrDivide=8 SysDivide=20
CLK_CFG ?= 133
ddr_clk_snap = $(DDR_CLK_DIR)/$(1)/xsim.dir/$(DDR_CLK_TOP)_sim/xsimk

# ---------------------------------------------------------- HyperRAM pads
# Configurations of bow_hyperram_io_xilinx (xelab -generic_top of the
# testbench), all on bow_hyperram_clk_xusp as the MPS4 sets it up (100 MHz,
# 672 phase steps):
#   card    level shifter pins (HasLs 1, Loopback 0): the MPS4 FMC+ card
#   direct  no level shifter pins (HasLs 0): a board without shifters
#   lb      loopback (Loopback 1, HasLs 0): the MPS4 loopback build,
#           bow_hyperram_dev behind the pads
HR_IO_TOP   := tb_bow_hyperram_io_xilinx
HR_IO_DIR   ?= $(BUILD)/hr_io
HR_IO_RTL   ?= $(REPO)/hw/fpga/common/rtl/bow_hyperram_io_xilinx.sv
HR_CLK_RTL  ?= $(REPO)/hw/fpga/common/rtl/bow_hyperram_clk_xusp.sv
HR_IO_SRCS   = $(REPO)/hw/ip/hyperram/rtl/bow_hyperram_pkg.sv $(HR_CLK_RTL) $(HR_IO_RTL) \
               $(CURDIR)/$(HR_IO_TOP).sv
HR_IO_CFGS  ?= card direct lb
HR_IO_GEN_card   :=
HR_IO_GEN_direct := HasLs=0
HR_IO_GEN_lb     := Loopback=1 HasLs=0
HR_IO_CFG ?= card
hr_io_snap = $(HR_IO_DIR)/$(1)/xsim.dir/$(HR_IO_TOP)_sim/xsimk

# a configuration name has to be one of the lists above
ifneq ($(filter run-ddr-io,$(MAKECMDGOALS)),)
  ifeq ($(origin DDR_IO_GEN_$(IO_CFG)),undefined)
    $(error unknown IO_CFG $(IO_CFG): card, x16, lb or lb16)
  endif
endif
ifneq ($(filter run-ddr-clk,$(MAKECMDGOALS)),)
  ifeq ($(origin DDR_CLK_GEN_$(CLK_CFG)),undefined)
    $(error unknown CLK_CFG $(CLK_CFG): 133 or 125)
  endif
endif
ifneq ($(filter run-hr-io,$(MAKECMDGOALS)),)
  ifeq ($(origin HR_IO_GEN_$(HR_IO_CFG)),undefined)
    $(error unknown HR_IO_CFG $(HR_IO_CFG): card, direct or lb)
  endif
endif

build: check-tools $(SNAP) $(foreach c,$(DDR_IO_CFGS),$(call ddr_io_snap,$(c))) \
       $(foreach c,$(DDR_CLK_CFGS),$(call ddr_clk_snap,$(c))) \
       $(foreach c,$(HR_IO_CFGS),$(call hr_io_snap,$(c)))

check-tools:
	@command -v $(XVLOG) >/dev/null 2>&1 && test -n "$$XILINX_VIVADO" || \
	  { echo "xvlog not found: source <Vivado>/settings64.sh"; exit 1; }

# ------------------------------------------------------------- D-PHY I/O
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

test-dphy: check-tools $(SNAP)
	@set -e; for s in $(SEEDS); do $(MAKE) --no-print-directory run SEED=$$s; done

# ---------------------------------------------- DDR pads, clocks, HyperRAM
# One library + snapshot directory per configuration (xelab -generic_top);
# rebuilt when a source or WAVES changes.
$(DDR_IO_DIR)/%/xsim.dir/$(DDR_IO_TOP)_sim/xsimk: $(DDR_IO_SRCS) $(DDR_IO_DIR)/%/debug_$(DEBUG)
	cd $(DDR_IO_DIR)/$* && $(XVLOG) -sv $(DDR_IO_SRCS) > xvlog.log 2>&1 || \
	  { tail -20 xvlog.log; exit 1; }
	cd $(DDR_IO_DIR)/$* && $(XVLOG) $(GLBL) > xvlog_glbl.log 2>&1 || \
	  { tail -20 xvlog_glbl.log; exit 1; }
	cd $(DDR_IO_DIR)/$* && $(XELAB) $(XELAB_OPTS) $(addprefix -generic_top ,$(DDR_IO_GEN_$*)) \
	  -s $(DDR_IO_TOP)_sim work.$(DDR_IO_TOP) work.glbl > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }

$(DDR_CLK_DIR)/%/xsim.dir/$(DDR_CLK_TOP)_sim/xsimk: $(DDR_CLK_SRCS) $(DDR_CLK_DIR)/%/debug_$(DEBUG)
	cd $(DDR_CLK_DIR)/$* && $(XVLOG) -sv $(DDR_CLK_SRCS) > xvlog.log 2>&1 || \
	  { tail -20 xvlog.log; exit 1; }
	cd $(DDR_CLK_DIR)/$* && $(XVLOG) $(GLBL) > xvlog_glbl.log 2>&1 || \
	  { tail -20 xvlog_glbl.log; exit 1; }
	cd $(DDR_CLK_DIR)/$* && $(XELAB) $(XELAB_OPTS) $(addprefix -generic_top ,$(DDR_CLK_GEN_$*)) \
	  -s $(DDR_CLK_TOP)_sim work.$(DDR_CLK_TOP) work.glbl > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }

$(HR_IO_DIR)/%/xsim.dir/$(HR_IO_TOP)_sim/xsimk: $(HR_IO_SRCS) $(HR_IO_DIR)/%/debug_$(DEBUG)
	cd $(HR_IO_DIR)/$* && $(XVLOG) -sv $(HR_IO_SRCS) > xvlog.log 2>&1 || \
	  { tail -20 xvlog.log; exit 1; }
	cd $(HR_IO_DIR)/$* && $(XVLOG) $(GLBL) > xvlog_glbl.log 2>&1 || \
	  { tail -20 xvlog_glbl.log; exit 1; }
	cd $(HR_IO_DIR)/$* && $(XELAB) $(XELAB_OPTS) $(addprefix -generic_top ,$(HR_IO_GEN_$*)) \
	  -s $(HR_IO_TOP)_sim work.$(HR_IO_TOP) work.glbl > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }

# WAVES stamps, explicit targets (a missing intermediate file would not
# trigger a rebuild)
$(foreach c,$(sort $(DDR_IO_CFGS) $(IO_CFG)),$(DDR_IO_DIR)/$(c)/debug_$(DEBUG)) \
$(foreach c,$(sort $(DDR_CLK_CFGS) $(CLK_CFG)),$(DDR_CLK_DIR)/$(c)/debug_$(DEBUG)) \
$(foreach c,$(sort $(HR_IO_CFGS) $(HR_IO_CFG)),$(HR_IO_DIR)/$(c)/debug_$(DEBUG)):
	@mkdir -p $(@D)
	rm -f $(@D)/debug_*
	touch $@

# xsim_run <snapshot dir> <run dir> <testbench> <seed>
xsim_mode = $(if $(filter 1,$(WAVES)),-wdb $(1).wdb -tclbatch waves.tcl,-R)
define xsim_run
@mkdir -p $(2)
@rm -f $(2)/sim.log
@printf 'log_wave -recursive *\nrun -all\nquit\n' > $(2)/waves.tcl
cd $(2) && $(XSIM) $(3)_sim --xsimdir $(1)/xsim.dir -sv_seed $(4) -log sim.log \
  $(call xsim_mode,$(3)) > /dev/null 2>&1 || true
endef

IO_RUN = $(DDR_IO_DIR)/$(IO_CFG)/seed$(SEED)
run-ddr-io: check-tools $(call ddr_io_snap,$(IO_CFG))
	$(call xsim_run,$(DDR_IO_DIR)/$(IO_CFG),$(IO_RUN),$(DDR_IO_TOP),$(SEED))
	@grep -q "^$(DDR_IO_TOP): PASS" $(IO_RUN)/sim.log || \
	  { grep -E "ERROR|FAIL|Error" $(IO_RUN)/sim.log | head -20; \
	    echo "$(DDR_IO_TOP) $(IO_CFG) seed $(SEED): FAIL, see $(IO_RUN)/sim.log"; exit 1; }
	@echo "$(DDR_IO_TOP) $(IO_CFG) seed $(SEED): PASS"

CLK_RUN = $(DDR_CLK_DIR)/$(CLK_CFG)/run
run-ddr-clk: check-tools $(call ddr_clk_snap,$(CLK_CFG))
	$(call xsim_run,$(DDR_CLK_DIR)/$(CLK_CFG),$(CLK_RUN),$(DDR_CLK_TOP),$(SEED))
	@grep -q "^$(DDR_CLK_TOP): PASS" $(CLK_RUN)/sim.log || \
	  { grep -E "ERROR|FAIL|Error" $(CLK_RUN)/sim.log | head -20; \
	    echo "$(DDR_CLK_TOP) $(CLK_CFG): FAIL, see $(CLK_RUN)/sim.log"; exit 1; }
	@echo "$(DDR_CLK_TOP) $(CLK_CFG): PASS"

HR_RUN = $(HR_IO_DIR)/$(HR_IO_CFG)/seed$(SEED)
run-hr-io: check-tools $(call hr_io_snap,$(HR_IO_CFG))
	$(call xsim_run,$(HR_IO_DIR)/$(HR_IO_CFG),$(HR_RUN),$(HR_IO_TOP),$(SEED))
	@grep -q "^$(HR_IO_TOP): PASS" $(HR_RUN)/sim.log || \
	  { grep -E "ERROR|FAIL|Error" $(HR_RUN)/sim.log | head -20; \
	    echo "$(HR_IO_TOP) $(HR_IO_CFG) seed $(SEED): FAIL, see $(HR_RUN)/sim.log"; exit 1; }
	@echo "$(HR_IO_TOP) $(HR_IO_CFG) seed $(SEED): PASS"

test-ddr-io: check-tools $(foreach c,$(DDR_IO_CFGS),$(call ddr_io_snap,$(c)))
	@set -e; for c in $(DDR_IO_CFGS); do for s in $(SEEDS); do \
	  $(MAKE) --no-print-directory run-ddr-io IO_CFG=$$c SEED=$$s; done; done

test-ddr-clk: check-tools $(foreach c,$(DDR_CLK_CFGS),$(call ddr_clk_snap,$(c)))
	@set -e; for c in $(DDR_CLK_CFGS); do $(MAKE) --no-print-directory run-ddr-clk CLK_CFG=$$c; done

test-hr-io: check-tools $(foreach c,$(HR_IO_CFGS),$(call hr_io_snap,$(c)))
	@set -e; for c in $(HR_IO_CFGS); do for s in $(SEEDS); do \
	  $(MAKE) --no-print-directory run-hr-io HR_IO_CFG=$$c SEED=$$s; done; done

test: test-dphy test-ddr-io test-ddr-clk test-hr-io

# Each mutant gets its own DDR_IO_DIR / DDR_CLK_DIR and RTL copy, then runs
# run-ddr-io / run-ddr-clk of this Makefile (MUTANT_JOBS in parallel).
MUTANT_JOBS ?= 4
mutants: check-tools
	$(PYTHON) mutants.py --build $(BUILD)/mutants --jobs $(MUTANT_JOBS) $(MUTANTS)

clean:
	rm -rf $(BUILD)

.PHONY: build check-tools run test test-dphy test-ddr-io test-ddr-clk test-hr-io run-ddr-io \
        run-ddr-clk run-hr-io mutants clean
