# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Build checks shared by the FPGA camera builds, in plain tclsh (no Vivado):
hw/fpga/common/tcl/bus_skew_checks_test.tcl runs bow32_bus_skew_checks (the cells of every
set_bus_skew, called by tcl/build.tcl of kv260_cam and of the Huins camera build) on a
synthetic netlist and synthetic report_bus_skew texts. Skipped without tclsh.
Run: python3 -m unittest discover -s tools/tests
"""

import shutil
import subprocess
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


@unittest.skipIf(shutil.which("tclsh") is None, "tclsh not installed")
class BusSkewChecksTest(unittest.TestCase):
    def test_bus_skew_checks(self):
        """Good constraints pass; a selector of a list that matched nothing, cells outside
        the allowed hierarchies, a destination without a path and unreadable reports are
        flagged."""
        script = REPO / "hw/fpga/common/tcl/bus_skew_checks_test.tcl"
        r = subprocess.run(["tclsh", str(script)], capture_output=True, text=True, timeout=60,
                           check=False)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("bus_skew_checks_test: PASS", r.stdout)


if __name__ == "__main__":
    unittest.main()
