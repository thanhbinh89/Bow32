#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Generate the LiteDRAM controller core of bow_ddr (docs/ip/ddr.md).

    bow_ddr_litedram_gen.py <config.yml> <out_dir> [--check]

LiteDRAM (https://github.com/enjoy-digital/litedram, BSD-2-Clause, versions
pinned in requirements.txt) provides the controller: bank machines, refresh,
command scheduling, DFII (software access to the DRAM for initialization and
calibration), BIST and the native user port. Its PHYs do not fit the FMC DDR2
card of Bow32 (level shifters with direction pins, read eye far from the
clock, no DDR2 on UltraScale+), so the PHY is Bow32's own SystemVerilog PHY
(bow_ddr_phy) behind bow_ddr_dfi. This script builds the controller with a
"PHY" that only exports LiteDRAM's DFI as ports:

    clk, rst                 controller clock (CK / 4) and active high reset
    init_done, init_error    ddrctrl CSRs, set by the firmware after training
    user_clk, user_rst       = clk, controller reset
    user_port_native_0_*     native port: one BL8 burst per word (8 x DQ bits), not
                             gated by init_done (bow_ddr_win only starts an access
                             while the core is READY, and an access in flight must
                             be able to finish when the firmware clears init_done)
    wb_ctrl_*                Wishbone slave: CSRs (ddrctrl, sdram/DFII, BIST)
    dfi_p<n>_*               DFI phases 0..3 (n = DRAM clock within clk)

Both memory types use a 1:4 DFI and BL8, the burst of Bow32's PHY and DRAM
emulator. LiteDRAM itself runs DDR2 with BL4 on a 1:2 DFI; BL8 is a legal DDR2
burst length too, so for DDR2 this script sets BL8 in LiteDRAM's burst length
table (controller address alignment, READ to WRITE turnaround) and in the mode
register of the generated init sequence. DDR3 runs in DLL-off mode
(dll_off: true, CK <= 125 MHz, CL = CWL = 6), supported by LiteDRAM.

Controller settings: no auto-precharge (rows are closed with explicit PRE; the
Bow32 DRAM emulator and models do not support RDA / WRA), and tREFI rounded
DOWN to whole controller cycles (LiteDRAM rounds up: 7.83 us > 7.8 us).

No vendor primitive is used: the same core is simulated by Verilator and
synthesized by Vivado.

Products in <out_dir> (<name> = config file name without .yml):
    litedram_<name>.v           module litedram_<name>
    litedram_<name>_pkg.sv      its parameters for bow_ddr.sv (geometry, latencies, CK)
    csr.csv                     CSR map of wb_ctrl
    init.csv                    the JEDEC init sequence (testbenches)
    include/generated/*.h       csr.h, soc.h, mem.h, sdram_phy.h for the firmware
--check regenerates in a temporary directory and compares instead of writing.

Use Python 3.9 (the Makefile's venv): Migen names many signals from the
bytecode of the code that creates them, so another Python version generates the
same logic with other signal names and --check reports a difference.
"""

import argparse
import filecmp
import math
import os
import re
import sys
import tempfile

import yaml

HEADERS = ["csr.h", "soc.h", "mem.h", "sdram_phy.h"]
NPHASES = 4
TREFI_NS = 7800.0   # JEDEC maximum average refresh interval (Tc <= 85 C)

# DFII bits (litedram/init.py), for init.csv
DFII_BITS = {
    "DFII_CONTROL_SEL": 0x01, "DFII_CONTROL_CKE": 0x02, "DFII_CONTROL_ODT": 0x04,
    "DFII_CONTROL_RESET_N": 0x08, "DFII_COMMAND_CS": 0x01, "DFII_COMMAND_WE": 0x02,
    "DFII_COMMAND_CAS": 0x04, "DFII_COMMAND_RAS": 0x08,
}


def sdram_modules():
    """Memory chips that LiteDRAM does not have (name -> class)."""
    from litedram.modules import DDR2Module, _TechnologyTimings, _SpeedgradeTimings

    class IS43DR86400E(DDR2Module):
        """ISSI IS43DR86400E: 512 Mb DDR2, 64M x 8, 4 banks (FMC DDR2 card).

        Timings in ns are the slowest of the -25 / -3 / -37 grades; tCCD = 4
        clocks (BL8)."""
        nbanks = 4
        nrows  = 16384
        ncols  = 1024
        technology_timings = _TechnologyTimings(
            tREFI=64e6/8192, tWTR=(2, 7.5), tCCD=(4, None), tRRD=(2, 10), tRTP=(2, 7.5))
        speedgrade_timings = {"default": _SpeedgradeTimings(
            tRP=15, tRCD=15, tWR=15, tRFC=(None, 105), tFAW=(None, 37.5), tRAS=45)}

    return {"IS43DR86400E": IS43DR86400E}


def patch_ddr2_bl8():
    """DDR2 with BL8 instead of LiteDRAM's BL4 (see the module docstring)."""
    import litedram.common
    import litedram.init

    litedram.common.burst_lengths["DDR2"] = 8   # the dict is shared by every LiteDRAM module

    original = litedram.init.get_ddr2_phy_init_sequence

    def get_ddr2_phy_init_sequence(phy_settings, timing_settings):
        sequence, mr = original(phy_settings, timing_settings)
        bl8 = []
        for comment, a, ba, cmd, delay in sequence:
            if ba == 0 and "Mode Register" in comment:   # MR: A2..A0 = 010 (BL4) -> 011 (BL8)
                assert a & 0x7 == 0b010
                a, comment = a | 0b001, comment.replace("BL=4", "BL=8")
            bl8.append((comment, a, ba, cmd, delay))
        return bl8, mr

    litedram.init.get_ddr2_phy_init_sequence = get_ddr2_phy_init_sequence


def build_core(cfg, name, build_dir):
    from migen import ClockSignal, ResetSignal
    from litex.build.generic_platform import Pins, Subsignal
    from litex.build.io import CRG
    from litex.build.xilinx import XilinxPlatform
    from litex.gen import LiteXModule
    from litex.soc.integration.builder import Builder
    from litex.soc.integration.soc_core import SoCCore
    from litex.soc.interconnect import wishbone
    from litedram import modules as litedram_modules
    from litedram.common import PhySettings
    from litedram.core.controller import ControllerSettings
    from litedram.phy.dfi import Interface, DIR_M_TO_S
    from litedram.gen import get_common_ios, get_native_user_port_ios, LiteDRAMCoreControl

    class BowDDRPHY(LiteXModule):
        """DFI of the controller as dfi_p<n>_<field> ports (the PHY is SystemVerilog)."""
        def __init__(self, platform, module):
            geom = module.geom_settings
            databits = cfg["databits"]
            self.settings = PhySettings(
                phytype       = "BowDDRPHY",
                memtype       = cfg["memtype"],
                databits      = databits,
                dfi_databits  = 2*databits,
                nphases       = NPHASES,
                rdphase       = cfg["rdphase"],
                wrphase       = cfg["wrphase"],
                cl            = cfg["cl"],
                cwl           = cfg["cwl"],
                read_latency  = cfg["read_latency"],
                write_latency = cfg["write_latency"],
                with_dm       = cfg["with_dm"],
            )
            if cfg.get("dll_off", False):
                self.settings.dll_off = True   # DDR3 DLL-off init sequence (litedram/init.py)
            self.dfi = Interface(geom.addressbits, geom.bankbits, 1, 2*databits, NPHASES)
            fields = [(f, w, d) for f, w, d in self.dfi.phases[0].layout if f != "act_n"]  # act_n: DDR4
            platform.add_extension([("dfi", 0) + tuple(
                Subsignal("p{}_{}".format(n, f), Pins(w)) for n in range(NPHASES) for f, w, _ in fields)])
            pads = platform.request("dfi")
            for n, phase in enumerate(self.dfi.phases):
                for f, _, direction in fields:
                    pad, sig = getattr(pads, "p{}_{}".format(n, f)), getattr(phase, f)
                    self.comb += pad.eq(sig) if direction == DIR_M_TO_S else sig.eq(pad)

    class BowLiteDRAMCore(SoCCore):
        def __init__(self, platform):
            platform.add_extension(get_common_ios())
            sys_clk_freq = cfg["ck_freq"]/NPHASES
            SoCCore.__init__(self, platform, sys_clk_freq,
                cpu_type             = None,
                csr_data_width       = 32,
                integrated_rom_size  = 0,
                integrated_sram_size = 0,
                with_timer           = False,
                with_ctrl            = False,
                with_uart            = False)

            self.crg = CRG(platform.request("clk"), rst=platform.request("rst"))

            module_cls = sdram_modules().get(cfg["module"]) or getattr(litedram_modules, cfg["module"])
            module = module_cls(sys_clk_freq, "1:{}".format(NPHASES))
            # JEDEC: average refresh interval <= 7.8 us (Tc <= 85 C); LiteDRAM rounds up
            module.timing_settings.tREFI = math.floor(TREFI_NS * sys_clk_freq / 1e9)
            self.ddrphy = BowDDRPHY(platform, module)
            self.add_sdram("sdram",
                phy                   = self.ddrphy,
                module                = module,
                with_bist             = True,
                with_soc_interconnect = False,
                controller_settings   = ControllerSettings(
                    cmd_buffer_depth    = cfg["cmd_buffer_depth"],
                    with_auto_precharge = False))
            self.init_sequence = (self.ddrphy.settings, module.timing_settings)

            # Training status, written by the firmware (the native port is blocked until done).
            self.ddrctrl = LiteDRAMCoreControl()
            self.comb += platform.request("init_done").eq(self.ddrctrl.init_done.storage)
            self.comb += platform.request("init_error").eq(self.ddrctrl.init_error.storage)

            # CSR access for the Bow32 bus bridge.
            wb_bus = wishbone.Interface()
            self.bus.add_master(master=wb_bus)
            platform.add_extension(wb_bus.get_ios("wb_ctrl"))
            self.comb += wb_bus.connect_to_pads(platform.request("wb_ctrl"), mode="slave")

            self.comb += platform.request("user_clk").eq(ClockSignal())
            self.comb += platform.request("user_rst").eq(ResetSignal())

            # Native user port, straight through (see the module docstring).
            port = self.sdram.crossbar.get_port()
            platform.add_extension(get_native_user_port_ios("native_0", port.address_width, port.data_width))
            io = platform.request("user_port_native_0")
            self.comb += [
                port.cmd.valid.eq(io.cmd_valid),
                io.cmd_ready.eq(port.cmd.ready),
                port.cmd.we.eq(io.cmd_we),
                port.cmd.addr.eq(io.cmd_addr),
                port.wdata.valid.eq(io.wdata_valid),
                io.wdata_ready.eq(port.wdata.ready),
                port.wdata.we.eq(io.wdata_we),
                port.wdata.data.eq(io.wdata_data),
                io.rdata_valid.eq(port.rdata.valid),
                port.rdata.ready.eq(io.rdata_ready),
                io.rdata_data.eq(port.rdata.data),
            ]
            geom = module.geom_settings
            self.params = dict(
                Ddr3         = int(cfg["memtype"] == "DDR3"),
                DqBits       = cfg["databits"],
                AddrPins     = geom.addressbits,
                BankPins     = geom.bankbits,
                HasDm        = int(cfg["with_dm"]),
                HasResetN    = int(cfg["memtype"] == "DDR3"),
                NatBytes     = port.data_width // 8,
                NatAw        = port.address_width,
                MemBytes     = (port.data_width // 8) << port.address_width,
                ReadLatency  = cfg["read_latency"],
                WriteLatency = cfg["write_latency"],
                RdPhase      = cfg["rdphase"],
                WrPhase      = cfg["wrphase"],
                Cl           = cfg["cl"],
                Cwl          = cfg["cwl"],
                CkHz         = int(round(cfg["ck_freq"])),
                TRefi        = module.timing_settings.tREFI,
            )

    platform = XilinxPlatform("", io=[], toolchain="vivado")
    soc = BowLiteDRAMCore(platform)
    builder = Builder(soc, output_dir=build_dir, compile_gateware=False, compile_software=False)
    builder.build(build_name="litedram_" + name)
    return soc.init_sequence, soc.params


def params_pkg(name, params):
    """SystemVerilog package with the parameters of the core (bow_ddr.sv)."""
    width = max(len(k) for k in params)
    lines = ["// Parameters of the LiteDRAM core litedram_{} (hw/ip/ddr/rtl/bow_ddr.sv).".format(name),
             "// TRefi: controller cycles between REF commands.",
             "package litedram_{}_pkg;".format(name)]
    for k, v in params.items():
        kind = "bit         " if k in ("Ddr3", "HasDm", "HasResetN") else "int unsigned"
        val = "1'b{}".format(v) if kind.startswith("bit") else str(v)
        lines.append("  localparam {} {} = {};".format(kind, k.ljust(width), val))
    lines.append("endpackage")
    return "\n".join(lines) + "\n"


def init_csv(phy_settings, timing_settings):
    """The init sequence of sdram_phy.h as CSV: kind (ctrl = DFII control write,
    cmd = command on phase 0), address, bank, value, delay (cdelay loops)."""
    from litedram.init import get_sdram_phy_init_sequence
    sequence, _ = get_sdram_phy_init_sequence(phy_settings, timing_settings)
    lines = ["kind,address,bank,value,delay,comment"]
    for comment, a, ba, cmd, delay in sequence:
        kind = "ctrl" if "DFII_CONTROL" in cmd else "cmd"
        value = sum(DFII_BITS[flag.strip()] for flag in cmd.split("|"))
        lines.append("{},0x{:04x},{},0x{:02x},{},{}".format(kind, a, ba, value, delay, comment))
    return "\n".join(lines) + "\n"


def strip_dates(text):
    """Remove what LiteX writes into every file but does not come from the inputs: the
    date and the "git revision" (git rev-parse run in the LiteX package directory: the
    revision of whatever checkout holds the venv, or '--------'). Also drop the
    `timescale of the Verilog core: Bow32 RTL has none (testbenches set theirs), and a
    core with one makes Verilator report every Bow32 module parsed before it."""
    text = re.sub(r"(?m)^// (Date|LiteX sha1) +: .*\n", "", text)
    text = re.sub(r"(?m)^`timescale .*\n", "", text)
    text = re.sub(r"LiteX \([^)\n]*\)", "LiteX", text)   # hex, or '--------' without git
    return re.sub(r" on \d{4}-\d\d-\d\d \d\d:\d\d:\d\d", "", text)


def generate(config, build_dir, out_dir):
    name = os.path.splitext(os.path.basename(config))[0]
    with open(config) as f:
        cfg = yaml.safe_load(f)
    cfg["ck_freq"] = float(cfg["ck_freq"])
    if cfg["memtype"] == "DDR2":
        patch_ddr2_bl8()
    (phy_settings, timing_settings), params = build_core(cfg, name, build_dir)

    banner = "Generated by hw/ip/ddr/litedram/bow_ddr_litedram_gen.py from {} - do not edit.\n".format(
        os.path.basename(config))
    files = [(os.path.join("gateware", "litedram_{}.v".format(name)), "litedram_{}.v".format(name), "// "),
             ("csr.csv", "csr.csv", "# ")]
    for h in HEADERS:
        files.append((os.path.join("software", "include", "generated", h),
                      os.path.join("include", "generated", h), "// "))
    with open(os.path.join(build_dir, "init.csv"), "w") as f:
        f.write(init_csv(phy_settings, timing_settings))
    files.append(("init.csv", "init.csv", "# "))
    pkg = "litedram_{}_pkg.sv".format(name)
    with open(os.path.join(build_dir, pkg), "w") as f:
        f.write(params_pkg(name, params))
    files.append((pkg, pkg, "// "))

    products = []
    for src, dst, comment in files:
        with open(os.path.join(build_dir, src)) as f:
            text = strip_dates(f.read())
        dst = os.path.join(out_dir, dst)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "w") as f:
            f.write(comment + banner + text)
        products.append(dst)
    return products


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("config", help="core configuration (YAML)")
    parser.add_argument("out_dir", help="directory for the products")
    parser.add_argument("--check", action="store_true",
                        help="regenerate in a temporary directory and compare with out_dir")
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 9):
        print("litedram: warning: Python {}.{} - the committed cores were generated with 3.9, "
              "signal names will differ".format(*sys.version_info[:2]))
    config = os.path.abspath(args.config)
    out_dir = os.path.abspath(args.out_dir)

    with tempfile.TemporaryDirectory(prefix="bow_ddr_litedram_") as tmp:
        build_dir = os.path.join(tmp, "build")
        if not args.check:
            generate(config, build_dir, out_dir)
            print("litedram: {} -> {}".format(os.path.basename(config), out_dir))
            return 0
        new_dir = os.path.join(tmp, "out")
        stale = []
        for path in generate(config, build_dir, new_dir):
            rel = os.path.relpath(path, new_dir)
            old = os.path.join(out_dir, rel)
            if not os.path.exists(old) or not filecmp.cmp(path, old, shallow=False):
                stale.append(rel)
        if stale:
            print("litedram: {} is not up to date ({}), run `make litedram`".format(
                out_dir, ", ".join(stale)))
            return 1
        print("litedram: {} up to date".format(out_dir))
        return 0


if __name__ == "__main__":
    sys.exit(main())
