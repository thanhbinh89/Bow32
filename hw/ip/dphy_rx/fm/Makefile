# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Formal equivalence of the D-PHY split (docs/ip/mipi_rx_arch.md, section 10, step 1):
# bow_csi2rx of a reference commit against bow_csi2rx of this tree (bow_dphy_rx
# inside), RTL against RTL, with Synopsys Formality (fm_shell in PATH and a Formality
# license; not part of CI). equiv.tcl describes the setup and the pass criteria.
#
#   make equiv                every configuration of CFGS (~30 s each)
#   make equiv-huins          one configuration
#   make equiv REF=<commit>   another reference (default: 3a1e780, main before step 1;
#                             a reference from step 1 on, with hw/ip/dphy_rx, works too)
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
CFGS    ?= kv260 huins lanes1 nophy sim
REF_DIR := $(BUILD)/ref
TIMEOUT ?= 3600

equiv: $(addprefix equiv-,$(CFGS))
	@echo "equiv: $(words $(CFGS)) configurations PASS against $(REF) ($(CFGS))"

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
	  -x "set cfg $*; set ref_root $(REF_DIR); set impl_root $(REPO)" \
	  -output_log_file fm.log -overwrite < /dev/null > fm.out 2>&1 || true
	@grep -h '^EQUIV ' $(BUILD)/$*/fm.out || echo "EQUIV $*: no result, see $(BUILD)/$*/fm.log"
	@grep -q '^EQUIV $*: PASS' $(BUILD)/$*/fm.out

clean:
	rm -rf $(BUILD)

.PHONY: equiv ref clean
