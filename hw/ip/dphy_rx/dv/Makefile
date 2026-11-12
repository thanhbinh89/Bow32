# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# Bench of the digital D-PHY alone (tb_bow_dphy_rx.sv: bow_dphy_rx with the bit level D-PHY
# transmitter of the receiver bench, csi2_tx_model.sv, on its AFE interface), step 6 of
# docs/ip/mipi_rx_arch.md (sections 4.12, 8.3, 10): the D-PHY v1.x functions, one test per run.
#
#   make test                    every test with 2 and with 4 lanes (+ the clock ratio cases),
#                                PJOBS of them at a time; fails if one fails
#   make run TEST=ulps LANES=4   one test (dumps nothing; the log in build/dphy_rx_dv/<name>.log)
#   make mutants                 the mutants of mutants_dphy.py (step 6 functions): each must
#                                make a test fail; not in test or CI
#   make test SEEDS="1 2 3"      the Verilator seeds of the synchronisers' jitter (default 1)
# Options: JOBS (C++ build jobs of Verilator, default 0: all cores), PJOBS (runs at a time,
# default: the number of CPUs), MJOBS (mutants at a time, default 4).
#
# The bench is built with BOW_CDC_JITTER and BOW_SYNC_JITTER: every synchroniser bit may
# resolve a new value one cycle late at random (hw/ip/common/rtl/bow_sync.sv, bow_cdc_pulse.sv),
# so a bus crossing that is not gray coded would show values it never had.

REPO      := $(abspath ../../../..)
BUILD     := $(REPO)/build/dphy_rx_dv
VERILATOR ?= verilator
PYTHON    ?= python3
JOBS      ?= 0
MJOBS     ?= 4
PJOBS     ?= $(shell nproc 2>/dev/null || echo 4)
SEEDS     ?= 1
TEST      ?= basic
LANES     ?= 2
SEED      ?= 1
PLUS      ?=

TESTS := basic apply tinit hstmo esctmo ulps hsrx missoff clklost lateeot gray
# the tests at other clocks: "name:plusargs"
CLOCKED := togdiv:+LP_PS=20000+BYTE_PS=10000 gray:+BUS_PS=50000

SRCS := $(shell find $(REPO)/hw/ip/dphy_rx $(REPO)/hw/ip/common $(REPO)/hw/ip/bus \
          -name '*.sv' -o -name '*.f') $(REPO)/hw/ip/csi2rx/rtl/bow_ppi_err_rx.sv \
        $(REPO)/hw/ip/csi2rx/dv/csi2_tx_model.sv $(REPO)/hw/fpga/common/rtl/bow_dphy_dly_xusp.sv \
        $(REPO)/hw/fpga/common/rtl/bow_dphy_dly_xphy.sv

bin = $(BUILD)/obj_l$(1)/Vtb_bow_dphy_rx
# A build, once more if it fails (Verilator 5.020 can abort at its exit after a good build,
# as in hw/ip/csi2rx/dv), then the binary is touched (an unchanged model stays as it was)
vbuild = { $(1) || $(1); } && touch $@
VDPHY = $(VERILATOR) --binary --timing -j $(JOBS) -O2 -Wno-fatal -Wno-lint -Wno-style \
  -Wno-TIMESCALEMOD +define+BOW_CDC_JITTER +define+BOW_SYNC_JITTER \
  --top-module tb_bow_dphy_rx -GLanes=$* -Mdir $(BUILD)/obj_l$* -o Vtb_bow_dphy_rx \
  -F $(REPO)/hw/ip/common/common.f -F $(REPO)/hw/ip/bus/bus.f -F $(REPO)/hw/ip/dphy_rx/dphy_rx.f \
  $(REPO)/hw/ip/csi2rx/rtl/bow_ppi_err_rx.sv $(REPO)/hw/fpga/common/rtl/bow_dphy_dly_xusp.sv \
  $(REPO)/hw/fpga/common/rtl/bow_dphy_dly_xphy.sv $(REPO)/hw/ip/csi2rx/dv/csi2_tx_model.sv \
  bow_ppi_chk.sv bow_afe_chk.sv tb_bow_dphy_rx.sv

$(BUILD)/obj_l%/Vtb_bow_dphy_rx: $(SRCS) tb_bow_dphy_rx.sv bow_ppi_chk.sv bow_afe_chk.sv
	@mkdir -p $(BUILD)
	$(call vbuild,$(VDPHY))

build: $(call bin,2) $(call bin,4)

# one test: "<name>: PASS / FAIL" from the bench's last line
NAME = $(TEST)_l$(LANES)$(if $(PLUS),_$(subst +,,$(subst =,,$(PLUS))))_s$(SEED)
run: $(call bin,$(LANES))
	@mkdir -p $(BUILD)
	@$(call bin,$(LANES)) +TEST=$(TEST) $(subst +, +,$(PLUS)) +verilator+seed+$(SEED) \
	  > $(BUILD)/$(NAME).log 2>&1; \
	  r=$$(grep -h '^tb_bow_dphy_rx: \(PASS\|FAIL\)' $(BUILD)/$(NAME).log | tail -1); \
	  if echo "$$r" | grep -q PASS; then echo "$(NAME): $$r"; \
	  else echo "$(NAME): FAIL ($${r:-no result, see $(BUILD)/$(NAME).log})"; \
	    grep -h 'ERROR\|Fatal\|check failed' $(BUILD)/$(NAME).log | head -5; exit 1; fi

cases:
	@for s in $(SEEDS); do for l in 2 4; do \
	  for t in $(TESTS); do echo "TEST=$$t LANES=$$l SEED=$$s"; done; \
	  for c in $(CLOCKED); do echo "TEST=$${c%%:*} PLUS=$${c#*:} LANES=$$l SEED=$$s"; done; \
	done; done

test: build
	@$(MAKE) --no-print-directory -s cases | xargs -P $(PJOBS) -L 1 $(MAKE) --no-print-directory run

mutants:
	$(PYTHON) mutants_dphy.py --build $(BUILD)/mutants --jobs $(MJOBS)

clean:
	rm -rf $(BUILD)

.PHONY: build run cases test mutants clean
