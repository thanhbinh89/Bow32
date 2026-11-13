# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Formal equivalence of the steps of the MIPI receiver split (docs/ip/mipi_rx_arch.md,
# section 10, steps 1, 2, 5, 6 and 7): the receiver of a reference commit against the receiver
# of this tree, RTL against RTL, with Synopsys Formality (fm_shell in PATH and a Formality
# license; not part of CI). The receiver's ports do not change up to step 2: bow_csi2rx up
# to step 1, bow_mipi_rx (bow_dphy_rx and the controller bow_csi2rx joined by the PPI) from
# step 2 on; step 4 changed the register map (no equivalence), step 5 the PHY ports into the
# AFE interface: its implementation top is bow_mipi_rx_s4.sv (this tree's receiver behind
# the ports of step 4) and its reference a tree of step 4, with the changes of step 5 listed
# in equiv.tcl. Step 6 (the D-PHY v1.x functions) is not equivalent as a whole by design:
# it proves two parts against a tree of step 5, the controller bow_csi2rx and the lane state
# machine bow_dphy_lp, with the new inputs at their reset values (equiv.tcl, "Step 6").
# Step 7 (the controller on its own clock csi_clk) moved the controller's datapath to another
# clock: the controller is not equivalent and not compared; it proves the D-PHY (bow_dphy_rx
# as a whole), the lane state machine and the controller's blocks that moved unchanged
# (packet layer, unpack, output, LOG capture, register file) against a tree of step 6, with
# no exception at all (equiv.tcl, "Step 7").
# equiv.tcl describes the setup, the rename rules and blocks of each step and
# the pass criteria: the rules of the steps between REF and this tree rename the
# implementation only, so against a reference from step 1 on (with hw/ip/dphy_rx) a cell
# that moved between the D-PHY and the controller fails, and no cell may sit in bow_mipi_rx
# itself.
#
#   make equiv                every configuration of CFGS (~30 s each), step STEP
#   make equiv-huins          one configuration
#   make equiv REF=<commit>   another reference (default: b832038, the end of step 6, as
#                             STEP=7 needs; STEP=6 took 1c76364, the end of step 5; STEP=5
#                             3d3985a, the end of step 4; STEP=2 3a1e780, main before step 1,
#                             or 35ef151, the end of step 1)
#   make equiv STEP=<n>       the implementation top and rename rules of step n (default 7,
#                             this tree; STEP=1, 2, 5 or 6 only fit a tree of that step)
#
# Configurations (equiv.tcl): kv260 (2 lanes, FIFO 256, taps in the byte clock domain:
# the KV260 camera build), huins (4 lanes, FIFO 512, taps in the video clock domain:
# the Huins camera build), lanes1 (1 lane), nophy (HasPhy 0 with a 50 MHz video clock:
# the KV260, MPS4 and Huins RAM card builds), sim (the system simulation's 107.5 MHz
# video clock); at step 6 these are the controller's parameters, and lp_data / lp_clk the
# lane state machine (data lane, clock lane), added to CFGS by default; at step 7 the
# D-PHY's (bow_mipi_rx's for it), with lp_data / lp_clk and the controller's blocks
# blk_packet2 / 4, blk_unpack1 / 4, blk_out, blk_capture, blk_regs, and the two clock FIFO
# bow_fifo_async (blk_afifo16, blk_afifo512: its synchronisers were rewritten). Outputs in
# build/dphy_rx_fm/: ref/ (the reference RTL, git archive of REF) and <cfg>/ (fm.log,
# fm.out, the reports of equiv.tcl).

REPO    := $(abspath ../../../..)
BUILD   := $(REPO)/build/dphy_rx_fm
FM      ?= fm_shell
REF     ?= b832038
STEP    ?= 7
CFGS    ?= kv260 huins lanes1 nophy sim $(if $(filter 6 7,$(STEP)),lp_data lp_clk) \
           $(if $(filter 7,$(STEP)),blk_packet2 blk_packet4 blk_unpack1 blk_unpack4 blk_out \
                                    blk_capture blk_regs blk_afifo16 blk_afifo512)
REF_DIR := $(BUILD)/ref
TIMEOUT ?= 3600

equiv: $(addprefix equiv-,$(CFGS))
	@echo "equiv: step $(STEP), $(words $(CFGS)) configurations PASS against $(REF) ($(CFGS))"

# The reference RTL, extracted again on every run (REF may change); hw/ip/dphy_rx too when
# REF has it
ref:
	@rm -rf $(REF_DIR)
	@mkdir -p $(REF_DIR)
	git -C $(REPO) archive $(REF) hw/ip/common hw/ip/bus hw/ip/csi2rx \
	  $$(git -C $(REPO) ls-tree -d --name-only $(REF) hw/ip/dphy_rx) | tar -x -C $(REF_DIR)
	@git -C $(REPO) rev-parse --verify $(REF)^{commit} > $(REF_DIR)/COMMIT

# fm_shell reads no terminal input (a script error then ends the session instead of
# waiting at the prompt) and gets TIMEOUT seconds.
equiv-%: ref
	@command -v $(FM) > /dev/null || { echo "$(FM) not found (Synopsys Formality)"; exit 1; }
	@mkdir -p $(BUILD)/$*
	cd $(BUILD)/$* && timeout $(TIMEOUT) $(FM) -file $(CURDIR)/equiv.tcl \
	  -x "set cfg $*; set step $(STEP); set ref_root $(REF_DIR); set impl_root $(REPO)" \
	  -output_log_file fm.log -overwrite < /dev/null > fm.out 2>&1 || true
	@grep -h '^EQUIV ' $(BUILD)/$*/fm.out || echo "EQUIV $*: no result, see $(BUILD)/$*/fm.log"
	@grep -q '^EQUIV $*: PASS' $(BUILD)/$*/fm.out

clean:
	rm -rf $(BUILD)

.PHONY: equiv ref clean
