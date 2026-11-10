# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
#
# System simulation with Verilator (>= 5.0, uses --binary --timing).
#
#   make build                 compile both builds of the testbench
#   make run TEST=boot         run one test (boot | load | break | flash | irq | gpio | camera | csi2 | h264 | mkv | ddr |
#                              hyperram | camera274 | csi2_274 | video274 | geo274), log build/sim/<test>.log
#   make test                  run all tests (TESTS), then a summary; fails if any failed
#   make test-extra            optional variants of the IMX274 tests (D-PHY corner, clock lane
#                              mode, BurstRxRst, full size modes), not in 'make test' or CI
#   make run TEST=load WAVES=1 also dump build/sim/waves.fst (open with GTKWave)
#   make run TEST=csi2_274 PLUSARGS="+DPHY_CORNER=2 +S274_CONTCLK=1"   more testbench plusargs
#   make run TEST=csi2_274 FW=brst0   csi2_test built for BurstRxRst = 0 with SETTLE 115 ns
#                              (model only: PA5 = 0 fails on silicon)
#   RUN_LOG=name               log build/sim/<name>.log instead of <test>.log
#   JOBS=8                     C++ build jobs of Verilator (default 0: all cores)
#
# Two builds of tb_bow32: the default one (KV260 camera: IMX219, 2 lanes,
# build/sim/obj) and Imx274 = 1 (Huins MFP-VP1902 camera: IMX274 on 4 lanes
# through the Versal PHY model, receiver FIFO 512, CsiDlyVid = 1, video clock
# 200 MHz, build/sim/obj-imx274) for the tests in TESTS_IMX274.

REPO      := $(abspath ..)
BUILD     := $(REPO)/build/sim
SW_BUILD  := $(REPO)/build/sw
VERILATOR ?= verilator
PYTHON    ?= python3
WAVES     ?= 0
JOBS      ?= 0
PLUSARGS  ?=

TEST    ?= boot
RUN_LOG ?= $(TEST)
TESTS   := boot load break flash irq gpio camera csi2 h264 mkv ddr hyperram camera274 csi2_274 video274
TESTS_IMX274 := camera274 csi2_274 video274 geo274

ROM_VMEM := $(SW_BUILD)/bootrom/bootrom.vmem

# Firmware used by each test
FLASH_boot  := $(SW_BUILD)/hello/hello.vmem
FLASH_break := $(SW_BUILD)/hello/hello.vmem
FLASH_flash := $(SW_BUILD)/flash_demo/flash_demo.vmem
FLASH_irq   := $(SW_BUILD)/uart_irq/uart_irq.vmem
FLASH_gpio  := $(SW_BUILD)/gpio_demo/gpio_demo.vmem
FLASH_camera := $(SW_BUILD)/camera/camera.vmem
FLASH_csi2  := $(SW_BUILD)/csi2_test/csi2_test.vmem
FLASH_h264  := $(SW_BUILD)/video/video.vmem
FLASH_mkv   := $(SW_BUILD)/mkv/mkv.vmem
FLASH_ddr   := $(SW_BUILD)/ddr/ddr.vmem
FLASH_hyperram := $(SW_BUILD)/hyperram/hyperram.vmem
FLASH_camera274 := $(SW_BUILD)/camera/camera.vmem
FLASH_csi2_274  := $(SW_BUILD)/csi2_test/csi2_test.vmem
FLASH_video274  := $(SW_BUILD)/video/video.vmem
FLASH_geo274    := $(SW_BUILD)/csi2_test/csi2_test.vmem
IMAGE_load  := $(SW_BUILD)/hello/hello.vmem

# Firmware variant FW=brst0 (csi2_274): csi2_test built for the other PHY
# setting of the Huins camera build, BurstRxRst = 0 (its receiver starts set
# PA5 = 0) with SETTLE 115 ns (sw/common/include/cam_sensor.h), into
# build/sim/sw-brst0/; the testbench then expects PA5 0 and SETTLE 115 ns.
# Model only: on the Huins board PA5 = 0 broke the link at the first receiver
# re-enable during a stream, at every SETTLE (docs/camera_huins.md 6.3).
FW ?=
SW_BRST0 := $(BUILD)/sw-brst0/csi2_test
ifeq ($(FW),brst0)
FLASH_csi2_274 := $(SW_BRST0)/csi2_test.vmem
FW_PLUSARGS    := +S274_PA5=0 +S274_SETTLE=115
else ifneq ($(FW),)
$(error unknown firmware variant FW=$(FW) (brst0))
endif

# H.264 streams the testbench writes into build/sim, decoded after the run,
# "<file>:<frames>[:bars]": that many frames, each with the 8 colour bars
# with :bars (h264_rc.hex: the rate control test, checker pattern)
H264_h264     := h264.hex:3:bars h264_rc.hex:8
H264_video274 := h264_274a.hex:3:bars h264_274b.hex:3:bars

# Separate model directories per build, with and without waveform tracing.
WAVES_SFX   := $(if $(filter 1,$(WAVES)),-waves)
OBJ_DIR     := $(BUILD)/obj$(WAVES_SFX)
OBJ_DIR_274 := $(BUILD)/obj-imx274$(WAVES_SFX)

RTL_FLISTS := -F $(REPO)/hw/top/bow32_top.f -F $(REPO)/hw/vendor/lowrisc_ibex_prim_generic.f
VFLAGS := --binary --timing -j $(JOBS) -O2 --x-assign fast --x-initial fast \
          -Wno-fatal -Wno-lint -Wno-style -Wno-TIMESCALEMOD \
          --top-module tb_bow32 -o Vtb_bow32
ifeq ($(WAVES),1)
VFLAGS += --trace-fst --trace-structs
endif

SIM_BIN     := $(OBJ_DIR)/Vtb_bow32
SIM_BIN_274 := $(OBJ_DIR_274)/Vtb_bow32
# the build of the selected test
RUN_BIN := $(if $(filter $(TEST),$(TESTS_IMX274)),$(SIM_BIN_274),$(SIM_BIN))
# The D-PHY transmitter model of the CSI-2 receiver tests (package
# csi2_tx_pkg + module csi2_tx_model), the DDR and the HyperRAM clock and pad
# models are compiled before the testbench.
TB_SRCS := $(REPO)/hw/ip/csi2rx/dv/csi2_tx_model.sv $(REPO)/hw/ip/ddr/dv/ddr_clk_model.sv \
           $(REPO)/hw/ip/ddr/dv/bow_ddr_io_sim.sv $(REPO)/hw/ip/hyperram/dv/hyperram_clk_model.sv \
           $(REPO)/hw/ip/hyperram/dv/bow_hyperram_io_sim.sv tb/tb_bow32.sv
# (*.v: the generated LiteDRAM cores of hw/ip/ddr/litedram/generated)
RTL_DEPS := $(shell find $(REPO)/hw/ip $(REPO)/hw/top -name '*.sv' -o -name '*.v' -o -name '*.f')

build: $(SIM_BIN) $(SIM_BIN_274)

$(SIM_BIN): $(TB_SRCS) $(RTL_DEPS)
	@mkdir -p $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(OBJ_DIR) $(REPO)/hw/lint/verilator_waivers.vlt $(RTL_FLISTS) $(TB_SRCS)

$(SIM_BIN_274): $(TB_SRCS) $(RTL_DEPS)
	@mkdir -p $(BUILD)
	$(VERILATOR) $(VFLAGS) -Mdir $(OBJ_DIR_274) -GImx274=1 $(REPO)/hw/lint/verilator_waivers.vlt \
	  $(RTL_FLISTS) $(TB_SRCS)

sw:
	$(MAKE) -C $(REPO)/sw all

sw-brst0:
	$(MAKE) -C $(REPO)/sw/apps/csi2_test all BUILD_DIR=$(SW_BRST0) \
	  EXTRA_CFLAGS="-DCAM_BURST_RST=0 -DSETTLE_VID_NS=115u"

run: $(RUN_BIN) sw $(if $(FW),sw-$(FW))
	cd $(BUILD) && $(RUN_BIN) +TEST=$(TEST) +ROM=$(ROM_VMEM) \
	  $(if $(FLASH_$(TEST)),+FLASH=$(FLASH_$(TEST))) \
	  $(if $(IMAGE_$(TEST)),+IMAGE=$(IMAGE_$(TEST))) \
	  $(if $(filter 1,$(WAVES)),+WAVES) $(FW_PLUSARGS) $(PLUSARGS) | tee $(BUILD)/$(RUN_LOG).log
	@grep -q "TEST PASSED" $(BUILD)/$(RUN_LOG).log
	@for e in $(H264_$(TEST)); do \
	  set -- $$(echo $$e | tr : ' '); f=$$1; bars=$${3:+--bars}; \
	  $(PYTHON) $(REPO)/tools/h264/h264_model.py decode $(BUILD)/$$f --hex $$bars --frames $$2 \
	    > $(BUILD)/$$f.txt 2>&1; r=$$?; \
	  cat $(BUILD)/$$f.txt; cat $(BUILD)/$$f.txt >> $(BUILD)/$(RUN_LOG).log; \
	  [ $$r = 0 ] || exit 1; \
	done

# Every test, also after a failure, then a summary
test: $(SIM_BIN) $(SIM_BIN_274) sw
	@fail=""; for t in $(TESTS); do \
	  s=$$(date +%s); \
	  if $(MAKE) --no-print-directory run TEST=$$t > /dev/null 2>&1; then \
	    echo "PASS  $$t ($$(( $$(date +%s) - s )) s)"; \
	  else \
	    echo "FAIL  $$t ($$(( $$(date +%s) - s )) s, see build/sim/$$t.log)"; fail="$$fail $$t"; \
	  fi; \
	done; \
	if [ -n "$$fail" ]; then echo "make test: FAILED:$$fail"; exit 1; fi; \
	echo "make test: all $(words $(TESTS)) tests passed"

# Optional variants of the IMX274 tests (a few minutes each, not in CI): the
# D-PHY corners and clock lane modes 'make test' does not run, BurstRxRst = 0
# (the firmware variant brst0: PA5 = 0 with SETTLE 115 ns at the longest
# HS-PREPARE, model only: it fails on silicon; the PHY model forced to 0
# without glitch words, and in the
# camera app with the FIFO drift), and the full size modes of the driver at
# the stream start (geo274). "<test> <name> [+plusarg | VAR=value]...";
# logs build/sim/<test>_<name>.log.
EXTRA := "csi2_274 corner2 +DPHY_CORNER=2" "csi2_274 contclk +S274_CONTCLK=1" \
         "csi2_274 brst0 FW=brst0" \
         "csi2_274 noglitch +S274_BURSTRST=0 +S274_GLITCH=0" \
         "camera274 corner1 +DPHY_CORNER=1 +S274_CONTCLK=0" \
         "camera274 brst0 +S274_BURSTRST=0" \
         "video274 corner0 +DPHY_CORNER=0 +S274_CONTCLK=0" \
         "geo274 1080p +S274_GEO=1080p" "geo274 720p +S274_GEO=720p"

test-extra: $(SIM_BIN_274) sw sw-brst0
	@fail=""; for v in $(EXTRA); do \
	  set -- $$v; t=$$1; n=$$1_$$2; shift 2; s=$$(date +%s); args=; vars=; \
	  for a in "$$@"; do case $$a in +*) args="$$args $$a";; *) vars="$$vars $$a";; esac; done; \
	  if $(MAKE) --no-print-directory run TEST=$$t RUN_LOG=$$n PLUSARGS="$$args" $$vars > /dev/null 2>&1; then \
	    echo "PASS  $$n ($$(( $$(date +%s) - s )) s)"; \
	  else \
	    echo "FAIL  $$n ($$(( $$(date +%s) - s )) s, see build/sim/$$n.log)"; fail="$$fail $$n"; \
	  fi; \
	done; \
	if [ -n "$$fail" ]; then echo "make test-extra: FAILED:$$fail"; exit 1; fi; \
	echo "make test-extra: all passed"

clean:
	rm -rf $(BUILD)

.PHONY: build run test test-extra sw sw-brst0 clean
