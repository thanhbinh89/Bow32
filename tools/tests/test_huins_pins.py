# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/huins_pins.py with a synthetic netlist workbook (the
real Huins netlist is confidential and not in the repo): the [all] / [clk=x]
/ [card=x] sections and the {site} template of pins.txt, the verified sites of
a card ([card=x sites=..], --any-site), the XDC lines, and every refused case
(net missing or with two FPGA pins, a ball used twice, a bad site, no clock
pins, an unknown card or section), whose messages never name a ball. Also:
hw/fpga/huins_vp1902/constr/pins.txt covers every port of each board top
(card ram: the RAM card top, card cam: the camera top), and the XPHY nibble
plan rules of the camera build (hw/fpga/huins_vp1902/tcl/cam_plan_test.tcl,
synthetic pin sets, skipped without tclsh). Skipped without openpyxl (only the
Huins target needs it). Run: python3 -m unittest discover -s tools/tests
"""

import contextlib
import io
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import huins_pins  # noqa: E402

try:
    import openpyxl
except ImportError:  # pragma: no cover
    openpyxl = None

REPO = Path(__file__).resolve().parents[2]
PINS_TXT = REPO / "hw/fpga/huins_vp1902/constr/pins.txt"
TOPS = {
    "ram": (REPO / "hw/fpga/huins_vp1902/rtl/bow32_huins_vp1902_top.sv", "10"),
    "cam": (REPO / "hw/fpga/huins_vp1902/rtl/bow32_huins_vp1902_cam_top.sv", "1"),
}

# single-card map (the format before card sections): still accepted for card ram
PINS_OLD = """\
# test map
[all]
led_o[0]      F_LED1
ddr_dq_io[0]  F_FMC{site}_HB07_P
[clk=ref200]
clk_p_i       C2_DDR4_SYS_CLK_P
clk_n_i       C2_DDR4_SYS_CLK_N
[clk=site]
clk_p_i       CLK_SI5341_FPGA_{site}_P
clk_n_i       CLK_SI5341_FPGA_{site}_N
"""

PINS = """\
# test map
[all]
led_o[0]      F_LED1
[card=ram]
ddr_dq_io[0]  F_FMC{site}_HB07_P
[card=cam sites=1]
mipi_clk_p_i  F_FMC{site}_CLK0_M2C_P   # comment after a pin
[clk=ref200]
clk_p_i       C2_DDR4_SYS_CLK_P
clk_n_i       C2_DDR4_SYS_CLK_N
[clk=site]
clk_p_i       CLK_SI5341_FPGA_{site}_P
clk_n_i       CLK_SI5341_FPGA_{site}_N
"""

NETS = [
    # net, (ref, pin) pairs; U1 = the FPGA (balls are made up)
    ("F_LED1", "U1", "AA1", "R10", "1"),
    ("F_FMC10_HB07_P", "FMC10", "J27", "U1", "BB2"),
    ("F_FMC1_HB07_P", "FMC1", "J27", "U1", "BB3"),
    ("F_FMC1_CLK0_M2C_P", "FMC1", "H4", "U1", "EE1"),
    ("F_FMC10_CLK0_M2C_P", "FMC10", "H4", "U1", "EE2"),
    ("C2_DDR4_SYS_CLK_P", "C100", "1", "U1", "CC4"),
    ("C2_DDR4_SYS_CLK_N", "C101", "1", "U1", "CC5"),
    ("CLK_SI5341_FPGA_10_P", "C200", "2", "U1", "DD6"),
    ("CLK_SI5341_FPGA_10_N", "C201", "2", "U1", "DD7"),
    ("GND", "R10", "2", None, None),
]


@unittest.skipIf(openpyxl is None, "openpyxl not installed")
class PinsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.pins = self.dir / "pins.txt"
        self.pins.write_text(PINS)
        self.netlist = self.dir / "netlist.xlsx"
        self.write_netlist(NETS)

    def tearDown(self):
        self.tmp.cleanup()

    def write_netlist(self, rows):
        wb = openpyxl.Workbook()
        wb.active.title = "other"
        ws = wb.create_sheet(huins_pins.SHEET)
        for row in rows:
            ws.append(list(row))
        wb.save(self.netlist)

    def run_tool(self, *extra):
        out = self.dir / "pins.xdc"
        out.unlink(missing_ok=True)
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            try:
                rc = huins_pins.main(["--netlist", str(self.netlist), "--pins", str(self.pins),
                                      "-o", str(out), *extra])
            except SystemExit as e:
                rc = e.code
                if isinstance(rc, str):     # SystemExit("message"): exit status 1
                    err.write(rc)
                    rc = 1
        return rc, (out.read_text() if out.exists() else ""), err.getvalue()

    @staticmethod
    def balls(xdc):
        return dict((m.group(2), m.group(1)) for m in
                    re.finditer(r"PACKAGE_PIN (\S+)\s+\[get_ports \{(\S+)\}\]", xdc))

    def test_ref200_site10(self):
        rc, xdc, _ = self.run_tool()
        self.assertEqual(rc, 0)
        self.assertEqual(self.balls(xdc), {"led_o[0]": "AA1", "ddr_dq_io[0]": "BB2",
                                           "clk_p_i": "CC4", "clk_n_i": "CC5"})
        self.assertIn("never commit", xdc)
        # the default card writes the header of the single-card tool
        self.assertIn("# site FMC+10, clock source ref200, 4 pins\n", xdc)
        rc, xdc2, _ = self.run_tool("--card", "ram")
        self.assertEqual(rc, 0)
        self.assertEqual(xdc2, xdc)

    def test_single_card_map(self):
        """A map without [card=...] sections is the ram card's, as before."""
        self.pins.write_text(PINS_OLD)
        rc, xdc, _ = self.run_tool()
        self.assertEqual(rc, 0)
        self.assertEqual(self.balls(xdc), {"led_o[0]": "AA1", "ddr_dq_io[0]": "BB2",
                                           "clk_p_i": "CC4", "clk_n_i": "CC5"})
        rc, _, err = self.run_tool("--card", "cam", "--site", "1")
        self.assertNotEqual(rc, 0)
        self.assertIn("no [card=cam] section", err)

    def test_site_clock_and_other_site(self):
        rc, xdc, _ = self.run_tool("--clk", "site")
        self.assertEqual(rc, 0)
        self.assertEqual(self.balls(xdc)["clk_p_i"], "DD6")
        rc, xdc, err = self.run_tool("--site", "1")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.balls(xdc)["ddr_dq_io[0]"], "BB3")

    def test_card_cam(self):
        rc, xdc, err = self.run_tool("--card", "cam", "--site", "1")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.balls(xdc), {"led_o[0]": "AA1", "mipi_clk_p_i": "EE1",
                                           "clk_p_i": "CC4", "clk_n_i": "CC5"})
        self.assertIn("# card cam, site FMC+1, clock source ref200, 4 pins\n", xdc)

    def test_card_cam_site_refused(self):
        # the camera top is only verified on FMC+01: another site needs --any-site
        rc, xdc, err = self.run_tool("--card", "cam", "--site", "10")
        self.assertNotEqual(rc, 0)
        self.assertEqual(xdc, "")
        self.assertIn("only verified on FMC+ site(s) 1", err)
        rc, xdc, err = self.run_tool("--card", "cam", "--site", "10", "--any-site")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.balls(xdc)["mipi_clk_p_i"], "EE2")

    def test_refused(self):
        # a net of the map without an FPGA pin
        self.write_netlist([r for r in NETS if r[0] != "F_LED1"])
        rc, _, err = self.run_tool()
        self.assertEqual(rc, 1)
        self.assertIn("F_LED1 has 0 FPGA pins", err)
        # a net with two FPGA pins
        self.write_netlist(NETS + [("F_LED1", "U1", "AA9")])
        rc, _, err = self.run_tool()
        self.assertEqual(rc, 1)
        self.assertIn("2 FPGA pins", err)
        # one ball for two ports
        self.write_netlist([("F_LED1", "U1", "BB2")] + [r for r in NETS if r[0] != "F_LED1"])
        rc, _, err = self.run_tool()
        self.assertEqual(rc, 1)
        self.assertIn("already used by", err)

    def test_errors_name_no_ball(self):
        """The error output never names a ball (confidential): a net with two FPGA pins
        (two cases), a net without one, two ports on one ball."""
        balls = {r[i + 1] for r in NETS for i in range(1, len(r) - 1, 2) if r[i] == "U1"}
        balls |= {"AA9"}
        for rows in (NETS + [("F_LED1", "U1", "AA9")],
                     NETS + [("F_FMC10_HB07_P", "U1", "AA9")],
                     [r for r in NETS if r[0] != "C2_DDR4_SYS_CLK_N"],
                     [("F_LED1", "U1", "BB2")] + [r for r in NETS if r[0] != "F_LED1"]):
            self.write_netlist(rows)
            rc, xdc, err = self.run_tool()
            self.assertEqual(rc, 1)
            self.assertEqual(xdc, "")
            self.assertIn("error: ", err)
            for ball in balls:
                self.assertIsNone(re.search(rf"\b{ball}\b", err), (ball, err))

    def test_bad_arguments(self):
        rc, _, _ = self.run_tool("--site", "5")
        self.assertNotEqual(rc, 0)
        rc, _, _ = self.run_tool("--clk", "nosuch")
        self.assertNotEqual(rc, 0)
        rc, _, err = self.run_tool("--card", "nosuch")
        self.assertNotEqual(rc, 0)
        self.assertIn("no [card=nosuch] section", err)
        rc, _, _ = self.run_tool("--card", "Bad Card")
        self.assertNotEqual(rc, 0)
        self.pins.write_text(PINS + "[card=cam]\nx F_LED1\n")   # a card twice
        rc, _, err = self.run_tool()
        self.assertNotEqual(rc, 0)
        self.assertIn("second [card=cam]", err)
        self.pins.write_text(PINS + "[cards=x]\n")               # unknown section
        rc, _, err = self.run_tool()
        self.assertNotEqual(rc, 0)
        self.assertIn("unknown section", err)
        self.pins.write_text("led_o[0] F_LED1\n")                # no section
        rc, _, _ = self.run_tool()
        self.assertNotEqual(rc, 0)


class MapTest(unittest.TestCase):
    def test_pins_txt_covers_the_tops(self):
        """Every scalar / bit of each top's ports has exactly one line per clock source."""
        for card, (top, site) in TOPS.items():
            src = top.read_text()
            ports = []
            for m in re.finditer(r"^\s*(input|output|inout)\s+(?:wire|logic)\s*(\[(\d+):0\])?\s*(\w+)",
                                 src, re.M):
                name, msb = m.group(4), m.group(3)
                ports += [f"{name}[{i}]" for i in range(int(msb) + 1)] if msb else [name]
            self.assertGreater(len(ports), 20, top)
            for clk in ("ref200", "site"):
                mapped = [p for p, _ in huins_pins.parse_pins(PINS_TXT, site, clk, card)]
                self.assertEqual(len(mapped), len(set(mapped)), (card, clk))
                self.assertEqual(sorted(mapped), sorted(ports), (card, clk))

    def test_camera_site_only_fmc01(self):
        """The camera map refuses the RAM card's default site (its nibble plan is FMC+01's)."""
        with self.assertRaises(SystemExit):
            huins_pins.parse_pins(PINS_TXT, "10", "ref200", "cam")
        pins = dict(huins_pins.parse_pins(PINS_TXT, "1", "ref200", "cam"))
        self.assertEqual(pins["mipi_clk_p_i"], "F_FMC1_CLK0_M2C_P")
        self.assertEqual(pins["fmc_prsnt_n_i"], "F_FMC1_PRSNT_N")
        self.assertNotIn("ddr_dq_io[0]", pins)


@unittest.skipIf(shutil.which("tclsh") is None, "tclsh not installed")
class CamPlanTest(unittest.TestCase):
    def test_plan_rules(self):
        """The camera build's XPHY nibble plan derivation (tcl/cam_plan.tcl) on synthetic
        pin sets: round trips of the testbench plans and every refusal."""
        script = REPO / "hw/fpga/huins_vp1902/tcl/cam_plan_test.tcl"
        r = subprocess.run(["tclsh", str(script)], capture_output=True, text=True, timeout=60,
                           check=False)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("cam_plan_test: PASS", r.stdout)


if __name__ == "__main__":
    unittest.main()
