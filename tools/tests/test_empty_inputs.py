# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""hw/lint/empty_inputs.py, the check of `make -C sim lint` for inputs connected to nothing
(`.pin ()` on an input; Verilator only has PINCONNECTEMPTY for empty pins of either
direction, waived for the normal empty outputs): a small design with an input left empty,
an inout left empty, an empty output and an omitted pin. Skipped without Verilator.
Run: python3 -m unittest discover -s tools/tests
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "hw" / "lint" / "empty_inputs.py"
VERILATOR = shutil.which(os.environ.get("VERILATOR", "verilator"))

DESIGN = """
module sub (input logic a, input logic [3:0] b, inout wire c, output logic y, output logic z);
  assign y = a;
  assign z = ^b;
endmodule
module top (input logic i, output logic o);
  wire w;
  sub u0 (.a (i), .b (4'h3), .c (w), .y (o), .z ());   // empty output: fine
  sub u1 (.a (), .b (4'h1), .c (w), .y (), .z ());     // empty input a
  sub u2 (.a (i), .b (4'h1), .c (), .y (), .z ());     // empty inout c
endmodule
"""


@unittest.skipIf(VERILATOR is None, "no Verilator")
class EmptyInputs(unittest.TestCase):

    def run_check(self, text, *extra):
        with tempfile.TemporaryDirectory() as tmp:
            sv = Path(tmp) / "t.sv"
            sv.write_text(text)
            r = subprocess.run([sys.executable, str(SCRIPT), "--verilator", VERILATOR, *extra,
                                "--", "-Wno-fatal", "--top-module", "top", str(sv)],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                               cwd=tmp)
            return r.returncode, r.stdout

    def test_finds_inputs_only(self):
        rc, out = self.run_check(DESIGN)
        self.assertEqual(rc, 1, out)
        self.assertIn("instance u1 (sub): input a connected to nothing", out)
        self.assertIn("instance u2 (sub): input c connected to nothing", out)
        self.assertNotIn("input z", out)
        self.assertNotIn("input y", out)
        self.assertIn("empty_inputs: top: 2 inputs connected to nothing", out)

    def test_clean(self):
        clean = DESIGN.replace(".a ()", ".a (i)").replace(".c ()", ".c (w)")
        rc, out = self.run_check(clean)
        self.assertEqual(rc, 0, out)
        self.assertIn("empty_inputs: top: 0 inputs connected to nothing", out)

    def test_exclude(self):
        rc, out = self.run_check(DESIGN, "--exclude", "*/t.sv")
        self.assertEqual(rc, 0, out)


if __name__ == "__main__":
    unittest.main()
