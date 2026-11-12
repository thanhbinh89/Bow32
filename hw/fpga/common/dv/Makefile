# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Pin level tests of the UltraScale+ I/O and clock wrappers in the Vivado
# simulator with the unisim models (each testbench describes its stimulus and
# its checks):
#   tb_bow_dphy_io_xusp   KV260 D-PHY AFE adapter (bow_dphy_io_xusp with its logic
#                         bow_dphy_dly_xusp) + bow_mipi_rx
#   tb_bow_ddr_io_xilinx  DDR2/DDR3 pads (bow_ddr_io_xilinx) on bow_ddr_clk_xusp,
#                         configurations DDR_IO_CFGS (below)
#   tb_bow_ddr_clk_xusp   DDR clocks (bow_ddr_clk_xusp: three MMCME4_ADV, fine
#                         phase shift, LiteDRAM controller clock CK / 4),
#                         configurations DDR_CLK_CFGS
#   tb_bow_hyperram_io_xilinx  HyperRAM pads (bow_hyperram_io_xilinx) on their
#                         clocks (bow_hyperram_clk_xusp: two MMCME4_ADV, fine
#                         phase shift of the write and read clocks, lock-loss
#                         reset), configurations HR_IO_CFGS
#   tb_bow_ddr_clk_versal, tb_bow_hyperram_clk_versal  Versal DDR / HyperRAM
#                         clocks (bow_ddr_clk_versal, bow_hyperram_clk_versal:
#                         two MMCME5 each, fine phase shift driven through
#                         bow_mmcm_ps, lock-loss reset), configurations VCLK_CFGS
#   tb_bow_dphy_io_versal Versal D-PHY AFE adapter (bow_dphy_io_versal: IBUFDS_DPHY,
#                         XPHY strobe mode, XPLL, BUFGCE, with its logic
#                         bow_dphy_dly_xphy; secureip XPHY model), configurations
#                         DPHYV_CFGS
#
#   make test                 all of them: D-PHY, DDR and HyperRAM pads with every
#                             seed of SEEDS, DDR clocks, Versal clocks and the Versal
#                             D-PHY once per configuration
#   make test SEEDS="1 2 3 4"
#   make run SEED=5 WAVES=1   D-PHY, one seed, waveform database in build/fpga_dv/seed5
#   make test-dphy | test-ddr-io | test-ddr-clk | test-hr-io     one testbench
#   make run-ddr-io IO_CFG=lb SEED=2 WAVES=1        one pad configuration and seed,
#                                                   files in build/fpga_dv/ddr_io/lb/seed2
#   make run-ddr-clk CLK_CFG=125 WAVES=1            one clock configuration,
#                                                   files in build/fpga_dv/ddr_clk/125/run
#   make run-hr-io HR_IO_CFG=lb SEED=2 WAVES=1      one HyperRAM configuration and seed,
#                                                   files in build/fpga_dv/hr_io/lb/seed2
#   make test-vclk                                  Versal clocks, every VCLK_CFGS (in make test)
#   make run-vclk VCLK_CFG=hr100 WAVES=1            one Versal clock configuration,
#                                                   files in build/fpga_dv/vclk/hr100/run
#   make test-dphy-versal                           Versal D-PHY, every DPHYV_CFGS (in make test)
#   make run-dphy-versal DPHYV_CFG=reinit_idle WAVES=1  one Versal D-PHY configuration,
#                                                   files in build/fpga_dv/dphy_versal/<cfg>/run
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
FLISTS := $(REPO)/hw/ip/common/common.f $(REPO)/hw/ip/bus/bus.f $(REPO)/hw/ip/dphy_rx/dphy_rx.f \
          $(REPO)/hw/ip/csi2rx/csi2rx.f
# The sources of the last files.txt, as far as they still exist: a file that left the
# file lists (moved or renamed) must not become a missing prerequisite. files.txt is
# remade from the lists, which rebuilds the snapshot anyway.
SRCS    = $(filter %.sv %.v,$(wildcard $(shell cat $(BUILD)/files.txt 2>/dev/null))) \
          $(CURDIR)/$(TOP).sv

# --------------------------------------------------------------- DDR pads
# Configurations of bow_ddr_io_xilinx (xelab -generic_top of the testbench):
#   card  x8, level shifter pins, CK as two single ended outputs, DIR read
#         level 1: the MPS4 FMC+ DDR2 card
#   x16   x16 with DM and RESET#, 16 address / 3 bank pins, CK on OBUFDS, DIR
#         read level 0
#   lb    x8 loopback (the MPS4 loopback build: bow_ddr_lb behind the pads)
#   lb16  x16 loopback with DM, no level shifter pins
#   vcard, vx16, vlb  the same with TFromOddr = 1 (Versal XPIO: T from an
#         ODDRE1 in the pad site; vcard = the Huins VP1902 card build)
DDR_IO_TOP   := tb_bow_ddr_io_xilinx
DDR_IO_DIR   ?= $(BUILD)/ddr_io
DDR_IO_RTL   ?= $(REPO)/hw/fpga/common/rtl/bow_ddr_io_xilinx.sv
DDR_CLK_RTL  ?= $(REPO)/hw/fpga/common/rtl/bow_ddr_clk_xusp.sv
DDR_IO_SRCS   = $(REPO)/hw/ip/ddr/rtl/bow_ddr_pkg.sv $(DDR_CLK_RTL) $(DDR_IO_RTL) \
                $(CURDIR)/$(DDR_IO_TOP).sv
DDR_IO_CFGS  ?= card x16 lb lb16 vcard vx16 vlb
DDR_IO_GEN_card :=
DDR_IO_GEN_x16  := DqBits=16 AddrPins=16 BankPins=3 HasDm=1 HasResetN=1 CkSingleEnded=0 \
                   LsDirReadLevel=0
DDR_IO_GEN_lb   := Loopback=1
DDR_IO_GEN_lb16 := DqBits=16 HasDm=1 HasLs=0 Loopback=1
DDR_IO_GEN_vcard := TFromOddr=1
DDR_IO_GEN_vx16  := $(DDR_IO_GEN_x16) TFromOddr=1
DDR_IO_GEN_vlb   := Loopback=1 TFromOddr=1
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
#   vcard, vdirect, vlb  the same with TFromOddr = 1 (Versal XPIO: T from an
#           ODDRE1 in the pad site; vcard = the Huins VP1902 card build)
HR_IO_TOP   := tb_bow_hyperram_io_xilinx
HR_IO_DIR   ?= $(BUILD)/hr_io
HR_IO_RTL   ?= $(REPO)/hw/fpga/common/rtl/bow_hyperram_io_xilinx.sv
HR_CLK_RTL  ?= $(REPO)/hw/fpga/common/rtl/bow_hyperram_clk_xusp.sv
HR_IO_SRCS   = $(REPO)/hw/ip/hyperram/rtl/bow_hyperram_pkg.sv $(HR_CLK_RTL) $(HR_IO_RTL) \
               $(CURDIR)/$(HR_IO_TOP).sv
HR_IO_CFGS  ?= card direct lb vcard vdirect vlb
HR_IO_GEN_card   :=
HR_IO_GEN_direct := HasLs=0
HR_IO_GEN_lb     := Loopback=1 HasLs=0
HR_IO_GEN_vcard   := TFromOddr=1
HR_IO_GEN_vdirect := HasLs=0 TFromOddr=1
HR_IO_GEN_vlb     := Loopback=1 HasLs=0 TFromOddr=1
HR_IO_CFG ?= card
hr_io_snap = $(HR_IO_DIR)/$(1)/xsim.dir/$(HR_IO_TOP)_sim/xsimk

# a configuration name has to be one of the lists above
ifneq ($(filter run-ddr-io,$(MAKECMDGOALS)),)
  ifeq ($(origin DDR_IO_GEN_$(IO_CFG)),undefined)
    $(error unknown IO_CFG $(IO_CFG): card, x16, lb, lb16, vcard, vx16 or vlb)
  endif
endif
ifneq ($(filter run-ddr-clk,$(MAKECMDGOALS)),)
  ifeq ($(origin DDR_CLK_GEN_$(CLK_CFG)),undefined)
    $(error unknown CLK_CFG $(CLK_CFG): 133 or 125)
  endif
endif
ifneq ($(filter run-hr-io,$(MAKECMDGOALS)),)
  ifeq ($(origin HR_IO_GEN_$(HR_IO_CFG)),undefined)
    $(error unknown HR_IO_CFG $(HR_IO_CFG): card, direct, lb, vcard, vdirect or vlb)
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
	echo $(REPO)/hw/fpga/common/rtl/bow_dphy_dly_xusp.sv >> $@
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

# ------------------------------------------------- Versal clock wrappers
# bow_ddr_clk_versal (tb_bow_ddr_clk_versal) and bow_hyperram_clk_versal
# (tb_bow_hyperram_clk_versal), two MMCME5 each, their phase ports driven
# directly and through bow_mmcm_ps. Configurations VCLK_CFGS (xelab
# -generic_top of the testbench; the name prefix ddr / hr selects it):
#   ddr200    DDR clocks from the Huins VP1902 200 MHz reference (differential,
#             VCO 200 * 16): 133.333 MHz, 768 fine phase steps per CK
#   ddr100    the same from a 100 MHz differential input (VCO 100 * 32)
#   ddr200se  200 MHz single ended input (DiffIn 0: IBUF)
#   hr200     HyperRAM clocks from 200 MHz (VCO 200 * 16): 100 MHz, 1024 steps
#   hr100     the same from 100 MHz (VCO 100 * 32)
# One xsim library + snapshot directory per configuration in
# $(VCLK_DIR)/<cfg>/, the run in $(VCLK_DIR)/<cfg>/run; rebuilt when a source
# or WAVES changes. DDR_VCLK_RTL / HR_VCLK_RTL replace the wrapper under test
# (a broken copy, say), VCLK_DIR the output directory.
VCLK_DIR      ?= $(BUILD)/vclk
DDR_VCLK_RTL  ?= $(REPO)/hw/fpga/common/rtl/bow_ddr_clk_versal.sv
HR_VCLK_RTL   ?= $(REPO)/hw/fpga/common/rtl/bow_hyperram_clk_versal.sv
DDR_VCLK_TOP  := tb_bow_ddr_clk_versal
HR_VCLK_TOP   := tb_bow_hyperram_clk_versal
DDR_VCLK_SRCS  = $(REPO)/hw/ip/common/rtl/bow_mmcm_ps.sv $(DDR_VCLK_RTL) $(CURDIR)/$(DDR_VCLK_TOP).sv
HR_VCLK_SRCS   = $(REPO)/hw/ip/common/rtl/bow_mmcm_ps.sv $(HR_VCLK_RTL) $(CURDIR)/$(HR_VCLK_TOP).sv
VCLK_CFGS     ?= ddr200 ddr100 ddr200se hr200 hr100
VCLK_GEN_ddr200   :=
VCLK_GEN_ddr100   := TIN=10.0 VcoMult=32
VCLK_GEN_ddr200se := DiffIn=0
VCLK_GEN_hr200    :=
VCLK_GEN_hr100    := TIN=10.0 VcoMult=32
VCLK_CFG ?= ddr200
vclk_top  = $(if $(filter ddr%,$(1)),$(DDR_VCLK_TOP),$(HR_VCLK_TOP))
vclk_snap = $(VCLK_DIR)/$(1)/xsim.dir/$(call vclk_top,$(1))_sim/xsimk

ifneq ($(filter run-vclk,$(MAKECMDGOALS)),)
  ifeq ($(origin VCLK_GEN_$(VCLK_CFG)),undefined)
    $(error unknown VCLK_CFG $(VCLK_CFG): ddr200, ddr100, ddr200se, hr200 or hr100)
  endif
endif

build: $(foreach c,$(VCLK_CFGS),$(call vclk_snap,$(c)))

$(VCLK_DIR)/ddr%/xsim.dir/$(DDR_VCLK_TOP)_sim/xsimk: $(DDR_VCLK_SRCS) $(VCLK_DIR)/ddr%/debug_$(DEBUG)
	cd $(VCLK_DIR)/ddr$* && $(XVLOG) -sv $(DDR_VCLK_SRCS) > xvlog.log 2>&1 || \
	  { tail -20 xvlog.log; exit 1; }
	cd $(VCLK_DIR)/ddr$* && $(XVLOG) $(GLBL) > xvlog_glbl.log 2>&1 || \
	  { tail -20 xvlog_glbl.log; exit 1; }
	cd $(VCLK_DIR)/ddr$* && $(XELAB) $(XELAB_OPTS) $(addprefix -generic_top ,$(VCLK_GEN_ddr$*)) \
	  -s $(DDR_VCLK_TOP)_sim work.$(DDR_VCLK_TOP) work.glbl > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }

$(VCLK_DIR)/hr%/xsim.dir/$(HR_VCLK_TOP)_sim/xsimk: $(HR_VCLK_SRCS) $(VCLK_DIR)/hr%/debug_$(DEBUG)
	cd $(VCLK_DIR)/hr$* && $(XVLOG) -sv $(HR_VCLK_SRCS) > xvlog.log 2>&1 || \
	  { tail -20 xvlog.log; exit 1; }
	cd $(VCLK_DIR)/hr$* && $(XVLOG) $(GLBL) > xvlog_glbl.log 2>&1 || \
	  { tail -20 xvlog_glbl.log; exit 1; }
	cd $(VCLK_DIR)/hr$* && $(XELAB) $(XELAB_OPTS) $(addprefix -generic_top ,$(VCLK_GEN_hr$*)) \
	  -s $(HR_VCLK_TOP)_sim work.$(HR_VCLK_TOP) work.glbl > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }

$(foreach c,$(sort $(VCLK_CFGS) $(VCLK_CFG)),$(VCLK_DIR)/$(c)/debug_$(DEBUG)):
	@mkdir -p $(@D)
	rm -f $(@D)/debug_*
	touch $@

VCLK_RUN = $(VCLK_DIR)/$(VCLK_CFG)/run
run-vclk: check-tools $(call vclk_snap,$(VCLK_CFG))
	$(call xsim_run,$(VCLK_DIR)/$(VCLK_CFG),$(VCLK_RUN),$(call vclk_top,$(VCLK_CFG)),$(SEED))
	@grep -q "^$(call vclk_top,$(VCLK_CFG)): PASS" $(VCLK_RUN)/sim.log || \
	  { grep -E "ERROR|FAIL|Error" $(VCLK_RUN)/sim.log | head -20; \
	    echo "$(call vclk_top,$(VCLK_CFG)) $(VCLK_CFG): FAIL, see $(VCLK_RUN)/sim.log"; exit 1; }
	@echo "$(call vclk_top,$(VCLK_CFG)) $(VCLK_CFG): PASS"

test-vclk: check-tools $(foreach c,$(VCLK_CFGS),$(call vclk_snap,$(c)))
	@set -e; for c in $(VCLK_CFGS); do $(MAKE) --no-print-directory run-vclk VCLK_CFG=$$c; done

.PHONY: run-vclk test-vclk

# ---------------------------------------------------------- Versal D-PHY
# bow_dphy_io_versal in tb_bow_dphy_io_versal (the testbench describes stimulus, plans and
# checks; ~20 s per configuration). Configurations DPHYV_CFGS (xelab -generic_top):
#   base             synthetic plan 0 (the RTL defaults: strobe local, inter-nibble,
#                    inter-byte both ways), 3 bursts, tap loads, merge / spacing contract
#   rden0 envtc_late the options RdenReg = 0, EnVtcEarly = 0
#   burstrst         des_rst_i = ~gate from reset (the D-PHY's CTRL.DES_RST_DIS = 0; the other
#                    configurations: des_rst_i = 0, as DES_RST_DIS = 1)
#   skew80 sweep     80 ps lane skew steps; tap sweep 0..511 (one burst per tap)
#   contclk          continuous clock lane, HS receiver on from reset (strobe toggles
#                    during BISC); contclk_late: HS turned on after phy_rdy
#   glitch           glitches on the clock lane at HS entry, glitch_burstrst with
#                    des_rst_i = ~gate
#   vtmode           merge of two requests in the first (VTC) wait
#   p1*, p2*         plan 1 (two nibbles), plan 2 (inter-byte and inter-nibble chains, 6 -> 8)
#   burstrst_on      des_rst_i switched on (DES_RST_DIS 1 -> 0) in the middle of a burst while
#                    streaming
#   reinit_idle      pd_i = 1 for 2 us (the D-PHY's AFE_CTRL.PD) with the clock lane in LP-11,
#                    after tap loads (the taps return to the BISC delays, OWN cleared)
#   reinit_toggle    pd_i while the clock lane toggles in HS (BISC with a running strobe),
#                    reinit_cont the same with the continuous clock
#   reinit_pulse     cal_start_i for 640 ns only: the pulse of the D-PHY's CMD.REINIT (32
#                    cycles of the 50 MHz bus clock; steps 4 and 5 of docs/ip/mipi_rx_arch.md)
# One xsim library + snapshot directory per configuration in $(DPHYV_DIR)/<cfg>/, the run
# in $(DPHYV_DIR)/<cfg>/run; rebuilt when a source or WAVES changes. DPHYV_RTL replaces
# the PHY under test (a broken copy, say), DPHYV_DIR the output directory. Needs the
# secureip library of Vivado (XPHY model): not part of CI.
DPHYV_DIR  ?= $(BUILD)/dphy_versal
DPHYV_RTL  ?= $(REPO)/hw/fpga/common/rtl/bow_dphy_io_versal.sv
DPHYV_TOP  := tb_bow_dphy_io_versal
DPHYV_SRCS  = $(REPO)/hw/ip/common/rtl/bow_sync.sv $(REPO)/hw/ip/common/rtl/bow_sync_bus.sv \
              $(REPO)/hw/fpga/common/rtl/bow_dphy_dly_xphy.sv $(DPHYV_RTL) $(CURDIR)/$(DPHYV_TOP).sv
DPHYV_CFGS ?= base rden0 envtc_late burstrst skew80 sweep contclk contclk_late glitch \
              glitch_burstrst vtmode p1 p1_skew80 p1_contclk p1_glitch p2 p2_sweep p2_glitch \
              p2_vtmode burstrst_on reinit_idle reinit_toggle reinit_cont p2_reinit_toggle \
              reinit_pulse
DPHYV_GEN_base             :=
DPHYV_GEN_rden0            := RdenReg=0
DPHYV_GEN_envtc_late       := EnVtcEarly=0
DPHYV_GEN_burstrst         := BurstRst=1
DPHYV_GEN_skew80           := SkewPs=80
DPHYV_GEN_sweep            := DlySweep=1 Bursts=2
DPHYV_GEN_contclk          := ContClk=1
DPHYV_GEN_contclk_late     := ContClk=2
DPHYV_GEN_glitch           := GlitchClk=8 GlitchPs=400
DPHYV_GEN_glitch_burstrst  := GlitchClk=8 GlitchPs=400 BurstRst=1
DPHYV_GEN_vtmode           := DlyTest=0
DPHYV_GEN_p1               := Plan=1
DPHYV_GEN_p1_skew80        := Plan=1 SkewPs=80
DPHYV_GEN_p1_contclk       := Plan=1 ContClk=1
DPHYV_GEN_p1_glitch        := Plan=1 GlitchClk=8 GlitchPs=400
DPHYV_GEN_p2               := Plan=2
DPHYV_GEN_p2_sweep         := Plan=2 DlySweep=1 Bursts=2
DPHYV_GEN_p2_glitch        := Plan=2 GlitchClk=8 GlitchPs=400 BurstRst=1
DPHYV_GEN_p2_vtmode        := Plan=2 DlyTest=0
DPHYV_GEN_burstrst_on      := GlitchClk=8 GlitchPs=400 BurstRstAt=1 Bursts=4
DPHYV_GEN_reinit_idle      := Reinit=1 Bursts=4
DPHYV_GEN_reinit_toggle    := Reinit=2 HsGate=0 Bursts=4
DPHYV_GEN_reinit_cont      := Reinit=1 ContClk=1 Bursts=4
DPHYV_GEN_p2_reinit_toggle := Plan=2 Reinit=2 HsGate=0 BurstRst=1 Bursts=4
DPHYV_GEN_reinit_pulse     := Reinit=1 ReinitNs=640 Bursts=4
DPHYV_CFG ?= base
dphyv_snap = $(DPHYV_DIR)/$(1)/xsim.dir/$(DPHYV_TOP)_sim/xsimk

ifneq ($(filter run-dphy-versal,$(MAKECMDGOALS)),)
  ifeq ($(origin DPHYV_GEN_$(DPHYV_CFG)),undefined)
    $(error unknown DPHYV_CFG $(DPHYV_CFG): one of $(DPHYV_CFGS))
  endif
endif

build: $(foreach c,$(DPHYV_CFGS),$(call dphyv_snap,$(c)))

$(DPHYV_DIR)/%/xsim.dir/$(DPHYV_TOP)_sim/xsimk: $(DPHYV_SRCS) $(DPHYV_DIR)/%/debug_$(DEBUG)
	cd $(DPHYV_DIR)/$* && $(XVLOG) -sv $(DPHYV_SRCS) > xvlog.log 2>&1 || \
	  { tail -20 xvlog.log; exit 1; }
	cd $(DPHYV_DIR)/$* && $(XVLOG) $(GLBL) > xvlog_glbl.log 2>&1 || \
	  { tail -20 xvlog_glbl.log; exit 1; }
	cd $(DPHYV_DIR)/$* && $(XELAB) $(XELAB_OPTS) $(addprefix -generic_top ,$(DPHYV_GEN_$*)) \
	  -s $(DPHYV_TOP)_sim work.$(DPHYV_TOP) work.glbl > xelab.log 2>&1 || { tail -20 xelab.log; exit 1; }

$(foreach c,$(sort $(DPHYV_CFGS) $(DPHYV_CFG)),$(DPHYV_DIR)/$(c)/debug_$(DEBUG)):
	@mkdir -p $(@D)
	rm -f $(@D)/debug_*
	touch $@

DPHYV_RUN = $(DPHYV_DIR)/$(DPHYV_CFG)/run
run-dphy-versal: check-tools $(call dphyv_snap,$(DPHYV_CFG))
	$(call xsim_run,$(DPHYV_DIR)/$(DPHYV_CFG),$(DPHYV_RUN),$(DPHYV_TOP),$(SEED))
	@grep -q "^$(DPHYV_TOP): PASS" $(DPHYV_RUN)/sim.log || \
	  { grep -E "ERROR|FAIL|Error" $(DPHYV_RUN)/sim.log | head -20; \
	    echo "$(DPHYV_TOP) $(DPHYV_CFG): FAIL, see $(DPHYV_RUN)/sim.log"; exit 1; }
	@echo "$(DPHYV_TOP) $(DPHYV_CFG): PASS"

test-dphy-versal: check-tools $(foreach c,$(DPHYV_CFGS),$(call dphyv_snap,$(c)))
	@set -e; for c in $(DPHYV_CFGS); do $(MAKE) --no-print-directory run-dphy-versal DPHYV_CFG=$$c; done

.PHONY: run-dphy-versal test-dphy-versal

test: test-dphy test-ddr-io test-ddr-clk test-hr-io test-vclk test-dphy-versal

# Each mutant gets its own DDR_IO_DIR / DDR_CLK_DIR and RTL copy, then runs
# run-ddr-io / run-ddr-clk of this Makefile (MUTANT_JOBS in parallel).
MUTANT_JOBS ?= 4
mutants: check-tools
	$(PYTHON) mutants.py --build $(BUILD)/mutants --jobs $(MUTANT_JOBS) $(MUTANTS)

clean:
	rm -rf $(BUILD)

.PHONY: build check-tools run test test-dphy test-ddr-io test-ddr-clk test-hr-io run-ddr-io \
        run-ddr-clk run-hr-io mutants clean
