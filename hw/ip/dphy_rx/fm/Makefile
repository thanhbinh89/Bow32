# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Formal equivalence of the steps of the MIPI receiver split (docs/ip/mipi_rx_arch.md,
# section 10, steps 1 and 2): the receiver of a reference commit against the receiver of
# this tree, RTL against RTL, with Synopsys Formality (fm_shell in PATH and a Formality
# license; not part of CI). The receiver's ports never change: bow_csi2rx up to step 1,
# bow_mipi_rx (bow_dphy_rx and the controller bow_csi2rx joined by the PPI) from step 2
# on. equiv.tcl describes the setup, the rename rules and blocks of each step and the pass
# criteria: the rules of the steps between REF and this tree rename the implementation
# only, so against a reference from step 1 on (with hw/ip/dphy_rx) a cell that moved
# between the D-PHY and the controller fails, and no cell may sit in bow_mipi_rx itself.
#
#   make equiv                every configuration of CFGS (~30 s each), step STEP
#   make equiv-huins          one configuration
#   make equiv REF=<commit>   another reference (default: 3a1e780, main before step 1, the
#                             end to end check; a reference from step 1 on also checks the
#                             blocks, e.g. 35ef151, the end of step 1)
#   make equiv STEP=<n>       the implementation top and rename rules of step n (default 2,
#                             this tree; STEP=1 only fits a tree of step 1)
#
# Configurations (equiv.tcl): kv260 (2 lanes, FIFO 256, taps in the byte clock domain:
# the KV260 camera build), huins (4 lanes, FIFO 512, taps in the video clock domain:
# the Huins camera build), lanes1 (1 lane), nophy (HasPhy 0 with a 50 MHz video clock:
# the KV260, MPS4 and Huins RAM card builds), sim (the system simulation's 107.5 MHz
# video clock). Outputs in build/dphy_rx_fm/: ref/ (the reference RTL, git archive of
# REF) and <cfg>/ (fm.log, fm.out, the reports of equiv.tcl).

REPO    := $(abspath ../../../..)
BUILD   := $(REPO)/build/dphy_rx_fm
FM      ?= fm_shell
REF     ?= 3a1e780
STEP    ?= 2
CFGS    ?= kv260 huins lanes1 nophy sim
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
