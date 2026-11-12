# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# CSI-2 receiver unit tests: RTL vs the reference model (tools/csi2/csi2_model.py).
# Whole receiver (bow_mipi_rx): the D-PHY side driven by csi2_tx_model.sv (lanes + receive
# I/O model), the registers of the controller (0x000) and of the D-PHY (0xC00, step 4 of
# docs/ip/mipi_rx_arch.md, section 10). PPI bench: the controller alone (bow_csi2rx), its
# PPI driven by bow_ppi_bfm.sv (step 3).
#
#   make test                          test-rx, then test-ppi
#   make test-rx                       aligner unit test, then random cases (SEEDS x lanes x
#                                      errors) and directed tests of the whole receiver, PJOBS
#                                      of them at a time
#   make test-ppi                      the PPI bench: random cases (SEEDS) and directed tests in
#                                      both timings, the D-PHY of Bow32 and a standard PHY
#   make run-ppi MODE=std TEST=loss LANES=4   one PPI case (MODE bow|std, the options of run),
#                                      dumps in build/csi2rx_dv/ppi_<MODE>_<name>
#   make mutants-ppi                   controller / wrapper mutants that the PPI bench must kill
#   make mutants-rx                    mutants only the whole receiver bench sees (RAW of the
#                                      D-PHY, the controller's gate of the aligner events)
#   make align                         aligner unit test only (tb_dphy_align.sv)
#   make run SEED=7 LANES=1 ERRORS=1   one random case, dumps in build/csi2rx_dv/<name>
#   make run TEST=clk                  one directed test (lp watchdog clk cmd ovf stop byteclk eye
#                                      skew deskew extra loss ovf2 ovf8 be rxoff, dly and raw
#                                      with LANES=4; be also covers the D-PHY's registers)
#   make run SEED=3 LANES=2 DUT_LANES=4 ERRORS=1    2 of the 4 lanes of the Huins receiver
#   make run SEED=3 LANES=4 ERRORS=1 BURSTRST=1     ... with BurstRxRst = 1 in the PHY model
#   make test SEEDS="1 2 3 4 5 6 7 8"
# Options of 'run': LANES (lanes used), DUT_LANES (Lanes parameter, default LANES),
# ERRORS=1, RAW8=1, CONTCLK=1, BURSTRST=1 (DUT_LANES=4). JOBS: C++ build jobs of
# Verilator (default 0: all cores). PJOBS: cases of test-rx / test-ppi run at a time
# (default: the number of CPUs; PJOBS=1: one after the other).
#
# One model per Lanes parameter: Lanes = 1 and 2 as on the KV260 (the
# UltraScale+ AFE adapter: a word every byte clock, IDELAY taps loaded in the
# byte clock domain, FIFO 256), Lanes = 4 as on the Huins camera build
# (AfeKind = 2, FIFO 512) with the Versal XPHY model of csi2_tx_model (RX
# FIFOs: latency, stale words, glitch words and wraps, hs_valid gaps; PHY ready
# after a delay, PHY re-init, BISC taps, delays in the video clock domain) at
# 180 MHz byte clock. csi2_tx_model runs the adapters' own logic
# (hw/fpga/common/rtl/bow_dphy_dly_xusp.sv, bow_dphy_dly_xphy.sv) on the D-PHY's
# AFE interface: the Versal PHY's re-init comes from cal_start / pd (CMD.REINIT,
# AFE_CTRL.PD), its BurstRxRst from des_rst (0 while CTRL.DES_RST_DIS = 1).
# BurstRxRst is 0 like the shipped camera build before step 4 (the FIFOs only
# restart at the PHY init; the test case writes DES_RST_DIS first), or 1
# (BURSTRST=1: they restart at every burst).
#
# PPI bench (tb_csi2rx_ppi.sv): one model per Lanes parameter (FIFO 512 with 4 lanes) and
# two DUTs, the one of the case's timing clocked: MODE bow, the D-PHY of Bow32 (bow_csi2rx,
# its PPI driven by bow_ppi_bfm; since step 4 no band: the PHY's registers are the
# D-PHY's, the window 0xC00 reads 0 here), MODE std, a standard PHY through the flat-port
# wrapper bow_csi2rx_ppi_flat. The model renders every burst of the test case at the PPI
# (csi2_model.py gen --ppi MODE); the expected results come from the same receiver model
# as above.

REPO      := $(abspath ../../../..)
BUILD     := $(REPO)/build/csi2rx_dv
VERILATOR ?= verilator
PYTHON    ?= python3
JOBS      ?= 0
MJOBS     ?= 4
MODEL     := $(PYTHON) $(REPO)/tools/csi2/csi2_model.py

SEEDS     ?= 1 2 3 4
SEED      ?= 1
TEST      ?= random
LANES     ?= 2
DUT_LANES ?= $(LANES)
ERRORS    ?= 0
RAW8      ?= 0
CONTCLK   ?= 0
BURSTRST  ?= 0
DIRECTED  := lp watchdog clk cmd ovf stop byteclk eye skew deskew extra loss ovf2 ovf8 be rxoff
# directed tests also run with 1 lane (Lanes = 1), with 1 lane of 2, and with
# the continuous clock (DLY read back while the byte clock runs); on the 4 lane
# receiver all of them (+ dly), and some with 2 of its 4 lanes
DIRECTED1 := cmd stop deskew extra ovf ovf2 loss be eye rxoff
DIRECTED12 := deskew extra ovf ovf2 loss eye
DIRECTEDC := be eye loss rxoff
DIRECTED4 := $(DIRECTED) dly raw
DIRECTED24 := cmd stop skew dly deskew extra ovf2 loss

# Testbench parameters and model options per Lanes parameter
PARAMS_1  := -GLanes=1
PARAMS_2  := -GLanes=2
PARAMS_4  := -GLanes=4 -GAfeKind=2 -GFifoDepth=512
PPARAMS_1 := -GLanes=1
PPARAMS_2 := -GLanes=2
PPARAMS_4 := -GLanes=4 -GFifoDepth=512
GENOPT_4   = --versal --fifo-depth 512 --burst-rst $(BURSTRST)

sim_bin  = $(BUILD)/obj_l$(1)/Vtb_bow_csi2rx
ppi_bin  = $(BUILD)/obj_ppi_l$(1)/Vtb_csi2rx_ppi
FLISTS  := -F $(REPO)/hw/ip/common/common.f -F $(REPO)/hw/ip/bus/bus.f \
           -F $(REPO)/hw/ip/dphy_rx/dphy_rx.f -F $(REPO)/hw/ip/csi2rx/csi2rx.f
# PPI v1 and AFE v1 checkers, bound into bow_dphy_rx by the testbench
PPI_CHK := $(REPO)/hw/ip/dphy_rx/dv/bow_ppi_chk.sv $(REPO)/hw/ip/dphy_rx/dv/bow_afe_chk.sv
# the AFE adapters' logic without primitives, which csi2_tx_model runs
AFE_DLY := $(REPO)/hw/fpga/common/rtl/bow_dphy_dly_xusp.sv \
           $(REPO)/hw/fpga/common/rtl/bow_dphy_dly_xphy.sv
SRCS    := $(shell find $(REPO)/hw/ip/csi2rx $(REPO)/hw/ip/dphy_rx $(REPO)/hw/ip/common \
                    $(REPO)/hw/ip/bus -name '*.sv' -o -name '*.f') $(AFE_DLY)
# A model build ($(1): the Verilator command), once more if it fails: Verilator 5.020 can
# abort at its exit after a good build ("attempted to destroy locked Thread Pool"), a real
# error fails twice. Then the binary is touched: Verilator leaves a model whose C++ did not
# change as it was, and a binary older than SRCS would make every case of the parallel runs
# (test-rx, test-ppi) build it again, all at once.
vbuild = { $(1) || $(1); } && touch $@

build: $(call sim_bin,1) $(call sim_bin,2) $(call sim_bin,4)
build-ppi: $(call ppi_bin,1) $(call ppi_bin,2) $(call ppi_bin,4)

# Aligner unit test: search window edges (deskew, sync errors, HS-PREPARE noise)
ALIGN_BIN := $(BUILD)/obj_align/Vtb_dphy_align
$(ALIGN_BIN): $(REPO)/hw/ip/dphy_rx/rtl/bow_dphy_align.sv tb_dphy_align.sv
	@mkdir -p $(BUILD)
	$(VERILATOR) --binary --timing -j $(JOBS) -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
	  --top-module tb_dphy_align -Mdir $(BUILD)/obj_align -o Vtb_dphy_align $^

align: $(ALIGN_BIN)
	@$(ALIGN_BIN) > $(BUILD)/align.log 2>&1; grep -h 'ERROR\|tb_dphy_align:' $(BUILD)/align.log; \
	  grep -q 'tb_dphy_align: PASS' $(BUILD)/align.log

# One model per Lanes parameter
VRX = $(VERILATOR) --binary --timing -j $(JOBS) -O2 -Wno-fatal -Wno-lint -Wno-style \
  -Wno-TIMESCALEMOD +define+BOW_CDC_JITTER \
  --top-module tb_bow_csi2rx $(PARAMS_$*) -Mdir $(BUILD)/obj_l$* -o Vtb_bow_csi2rx \
  $(FLISTS) $(AFE_DLY) csi2_tx_model.sv $(PPI_CHK) tb_bow_csi2rx.sv
$(BUILD)/obj_l%/Vtb_bow_csi2rx: $(SRCS)
	@mkdir -p $(BUILD)
	$(call vbuild,$(VRX))

# One case: generate, simulate, compare
flag = $(if $(filter 1,$($(1))),$(2))
NAME = $(TEST)$(if $(filter random,$(TEST)),_s$(SEED))_l$(LANES)$(if $(filter-out $(LANES),$(DUT_LANES)),of$(DUT_LANES))$(call flag,ERRORS,_err)$(call flag,RAW8,_raw8)$(call flag,CONTCLK,_cont)$(if $(filter 4,$(DUT_LANES)),$(call flag,BURSTRST,_brst))
CASE = $(BUILD)/$(NAME)
run: $(call sim_bin,$(DUT_LANES))
	@$(MODEL) gen $(CASE) --test $(TEST) --seed $(SEED) --lanes $(LANES) --dut-lanes $(DUT_LANES) \
	  $(call flag,ERRORS,--errors) $(call flag,RAW8,--raw8) $(call flag,CONTCLK,--contclk) \
	  $(GENOPT_$(DUT_LANES)) > /dev/null
	@$(call sim_bin,$(DUT_LANES)) +DIR=$(CASE) +verilator+seed+$(SEED) > $(CASE)/sim.log 2>&1 || \
	  { echo "$(CASE): simulation failed"; tail -5 $(CASE)/sim.log; exit 1; }
	@$(MODEL) check $(CASE) > $(CASE)/check.log 2>&1; r=$$?; cat $(CASE)/check.log; exit $$r

# The aligner unit test, then the cases: every seed 2 lanes with and without errors, 1
# lane (Lanes = 1) with errors, 1 lane used of 2 with and without errors; on the 4 lane
# receiver 4 lanes with and without errors and 4 lanes with errors once more with
# BurstRxRst = 1, 2 of 4 with and without errors, 1 of 4 with errors (4th field:
# BurstRxRst); RAW8 / continuous clock alternate. Then the directed tests (lists above;
# BurstRxRst = 0). The cases are independent: PJOBS of them run at a time (as in
# test-ppi), each prints its check line; the target fails if one failed.
PJOBS ?= $(shell nproc 2>/dev/null || echo 4)
rx-cases:
	@for s in $(SEEDS); do \
	  r=$$((s % 2)); c=$$((s / 2 % 2)); \
	  for cfg in "2 2 0 0" "2 2 1 0" "1 1 1 0" "1 2 0 0" "1 2 1 0" \
	             "4 4 0 0" "4 4 1 0" "4 4 1 1" "2 4 0 1" "2 4 1 0" "1 4 1 1"; do \
	    set -- $$cfg; \
	    echo "TEST=random SEED=$$s LANES=$$1 DUT_LANES=$$2 ERRORS=$$3 BURSTRST=$$4 RAW8=$$r CONTCLK=$$c"; \
	  done; \
	done; \
	for t in $(DIRECTED); do echo "TEST=$$t"; done; \
	for t in $(DIRECTED1); do echo "TEST=$$t LANES=1"; done; \
	for t in $(DIRECTED12); do echo "TEST=$$t LANES=1 DUT_LANES=2"; done; \
	for t in $(DIRECTEDC); do echo "TEST=$$t CONTCLK=1"; echo "TEST=$$t CONTCLK=1 LANES=4"; done; \
	for t in $(DIRECTED4); do echo "TEST=$$t LANES=4"; done; \
	for t in $(DIRECTED24); do echo "TEST=$$t LANES=2 DUT_LANES=4"; done

test-rx: build $(ALIGN_BIN)
	@fail=0; $(MAKE) --no-print-directory align || fail=1; \
	$(MAKE) --no-print-directory -s rx-cases | \
	  xargs -P $(PJOBS) -L 1 $(MAKE) --no-print-directory run || fail=1; \
	exit $$fail

# ------------------------------------------------------------------- PPI bench
MODE      ?= bow
PPI_SRCS  := $(REPO)/hw/ip/csi2rx/rtl/bow_csi2rx_ppi_flat.sv $(AFE_DLY) csi2_tx_model.sv \
             bow_ppi_bfm.sv tb_csi2rx_ppi.sv
PGENOPT_4 := --fifo-depth 512

VPPI = $(VERILATOR) --binary --timing -j $(JOBS) -O2 -Wno-fatal -Wno-lint -Wno-style \
  -Wno-TIMESCALEMOD +define+BOW_CDC_JITTER \
  --top-module tb_csi2rx_ppi $(PPARAMS_$*) -Mdir $(BUILD)/obj_ppi_l$* -o Vtb_csi2rx_ppi \
  $(FLISTS) $(PPI_SRCS)
$(BUILD)/obj_ppi_l%/Vtb_csi2rx_ppi: $(SRCS)
	@mkdir -p $(BUILD)
	$(call vbuild,$(VPPI))

PNAME = ppi_$(MODE)_$(TEST)$(if $(filter random,$(TEST)),_s$(SEED))_l$(LANES)$(if $(filter-out $(LANES),$(DUT_LANES)),of$(DUT_LANES))$(call flag,ERRORS,_err)$(call flag,RAW8,_raw8)$(call flag,CONTCLK,_cont)
PCASE = $(BUILD)/$(PNAME)
run-ppi: $(call ppi_bin,$(DUT_LANES))
	@$(MODEL) gen $(PCASE) --ppi $(MODE) --test $(TEST) --seed $(SEED) --lanes $(LANES) \
	  --dut-lanes $(DUT_LANES) $(call flag,ERRORS,--errors) $(call flag,RAW8,--raw8) \
	  $(call flag,CONTCLK,--contclk) $(PGENOPT_$(DUT_LANES)) > /dev/null
	@$(call ppi_bin,$(DUT_LANES)) +DIR=$(PCASE) +verilator+seed+$(SEED) > $(PCASE)/sim.log 2>&1 || \
	  { echo "$(PCASE): simulation failed"; tail -5 $(PCASE)/sim.log; exit 1; }
	@$(MODEL) check $(PCASE) > $(PCASE)/check.log 2>&1; r=$$?; cat $(PCASE)/check.log; exit $$r

# Both timings: every seed 2 lanes with and without errors, 1 lane (Lanes = 1) with
# errors, 1 of 2 with errors, 4 lanes with and without errors, 2 of 4 and 1 of 4 with
# errors, RAW8 / continuous clock alternating as in test-rx; the directed tests of the
# controller on 2 and on 4 lanes, some with 1 lane, 1 of 2, 2 of 4 and with the continuous
# clock (2 and 4 lanes); lpmask on 1, 2 and 4 lanes (ErrControlClk only in the timing of
# the D-PHY of Bow32). Then, in that timing only (the gaps of the XPHY), gaps on
# 1, 2 and 4 lanes. PJOBS cases run at a time (as in test-rx and the DDR / HyperRAM
# benches), each prints its check line; the target fails if one failed.
PPI_MODES      := bow std
PPI_DIRECTED   := cmd ovf stop skew deskew extra loss ovf2 ovf8 be clkstop
PPI_DIRECTED1  := cmd stop deskew extra ovf loss be clkstop
PPI_DIRECTED12 := deskew extra loss clkstop
PPI_DIRECTED24 := cmd stop skew deskew extra loss clkstop
PPI_DIRECTEDC  := be loss clkstop
PPI_DIRECTED3  := lpmask
PPI_BOW        := gaps
ppi-cases:
	@for m in $(PPI_MODES); do \
	  for s in $(SEEDS); do \
	    r=$$((s % 2)); c=$$((s / 2 % 2)); \
	    for cfg in "2 2 0" "2 2 1" "1 1 1" "1 2 1" "4 4 0" "4 4 1" "2 4 1" "1 4 1"; do \
	      set -- $$cfg; \
	      echo "MODE=$$m TEST=random SEED=$$s LANES=$$1 DUT_LANES=$$2 ERRORS=$$3 RAW8=$$r CONTCLK=$$c"; \
	    done; \
	  done; \
	  for t in $(PPI_DIRECTED); do echo "MODE=$$m TEST=$$t"; echo "MODE=$$m TEST=$$t LANES=4"; done; \
	  for t in $(PPI_DIRECTED1); do echo "MODE=$$m TEST=$$t LANES=1"; done; \
	  for t in $(PPI_DIRECTED12); do echo "MODE=$$m TEST=$$t LANES=1 DUT_LANES=2"; done; \
	  for t in $(PPI_DIRECTED24); do echo "MODE=$$m TEST=$$t LANES=2 DUT_LANES=4"; done; \
	  for t in $(PPI_DIRECTEDC); do \
	    echo "MODE=$$m TEST=$$t CONTCLK=1"; echo "MODE=$$m TEST=$$t CONTCLK=1 LANES=4"; \
	  done; \
	  for t in $(PPI_DIRECTED3); do for l in 1 2 4; do echo "MODE=$$m TEST=$$t LANES=$$l"; done; done; \
	done; \
	for t in $(PPI_BOW); do for l in 1 2 4; do echo "MODE=bow TEST=$$t LANES=$$l"; done; done

test-ppi: build-ppi
	@$(MAKE) --no-print-directory -s ppi-cases | \
	  xargs -P $(PJOBS) -L 1 $(MAKE) --no-print-directory run-ppi

# Both benches; fails at the end if either failed
test:
	@fail=0; $(MAKE) --no-print-directory test-rx || fail=1; \
	$(MAKE) --no-print-directory test-ppi || fail=1; exit $$fail

# Mutants of the controller and of the flat wrapper (mutants_ppi.py): each must make a case
# of the PPI bench fail; not in test or CI
mutants-ppi:
	$(PYTHON) mutants_ppi.py --build $(BUILD)/mutants_ppi --jobs $(MJOBS)

# Mutants of the D-PHY's RAW capture, of the controller's gate of the aligner events and of
# the AFE interface of step 5 (des_rst, OWN, lprx_en, the adapters' delay logic)
# (mutants_rx.py): each must make a case of the whole receiver bench fail (raw, rxoff, dly,
# be); not in test or CI
mutants-rx:
	$(PYTHON) mutants_rx.py --build $(BUILD)/mutants_rx --jobs $(MJOBS)

clean:
	rm -rf $(BUILD)

.PHONY: build build-ppi align run run-ppi rx-cases ppi-cases test test-rx test-ppi mutants-ppi \
        mutants-rx clean
