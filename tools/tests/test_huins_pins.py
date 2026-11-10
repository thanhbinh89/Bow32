# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/huins_pins.py with a synthetic netlist workbook (the
real Huins netlist is confidential and not in the repo): the [all] / [clk=x]
sections and the {site} template of pins.txt, the XDC lines, and every refused
case (net missing or with two FPGA pins, a ball used twice, a bad site, no
clock pins). Also: hw/fpga/huins_vp1902/constr/pins.txt covers every port of
the board top. Skipped without openpyxl (only the Huins target needs it). Run:
python3 -m unittest discover -s tools/tests
"""

import contextlib
import io
import re
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
TOP = REPO / "hw/fpga/huins_vp1902/rtl/bow32_huins_vp1902_top.sv"

PINS = """\
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

NETS = [
    # net, (ref, pin) pairs; U1 = the FPGA (balls are made up)
    ("F_LED1", "U1", "AA1", "R10", "1"),
    ("F_FMC10_HB07_P", "FMC10", "J27", "U1", "BB2"),
    ("F_FMC1_HB07_P", "FMC1", "J27", "U1", "BB3"),
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
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            try:
                rc = huins_pins.main(["--netlist", str(self.netlist), "--pins", str(self.pins),
                                      "-o", str(out), *extra])
            except SystemExit as e:
                rc = e.code
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

    def test_site_clock_and_other_site(self):
        rc, xdc, _ = self.run_tool("--clk", "site")
        self.assertEqual(rc, 0)
        self.assertEqual(self.balls(xdc)["clk_p_i"], "DD6")
        rc, xdc, err = self.run_tool("--site", "1")
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.balls(xdc)["ddr_dq_io[0]"], "BB3")

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

    def test_bad_arguments(self):
        rc, _, _ = self.run_tool("--site", "5")
        self.assertNotEqual(rc, 0)
        rc, _, _ = self.run_tool("--clk", "nosuch")
        self.assertNotEqual(rc, 0)
        self.pins.write_text("led_o[0] F_LED1\n")   # no section
        rc, _, _ = self.run_tool()
        self.assertNotEqual(rc, 0)


class MapTest(unittest.TestCase):
    def test_pins_txt_covers_the_top(self):
        """Every scalar / bit of a top-level port has exactly one line per clock source."""
        src = TOP.read_text()
        ports = []
        for m in re.finditer(r"^\s*(input|output|inout)\s+(?:wire|logic)\s*(\[(\d+):0\])?\s*(\w+)",
                             src, re.M):
            name, msb = m.group(4), m.group(3)
            ports += [f"{name}[{i}]" for i in range(int(msb) + 1)] if msb else [name]
        for clk in ("ref200", "site"):
            mapped = [p for p, _ in huins_pins.parse_pins(PINS_TXT, "10", clk)]
            self.assertEqual(len(mapped), len(set(mapped)), clk)
            self.assertEqual(sorted(mapped), sorted(ports), clk)


if __name__ == "__main__":
    unittest.main()
