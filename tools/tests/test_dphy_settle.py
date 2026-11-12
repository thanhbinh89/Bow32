# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""SETTLE of the D-PHY driver on the host: bow_dphy_rx_settle() of
sw/common/include/bow_dphy_rx.h (the one formula for every PHY since step 4 of
docs/ip/mipi_rx_arch.md, docs/ip/dphy_rx.md) compiled with the host C compiler, against
the two formulas of the driver before step 4 (bow_csi2rx.c: settle_cycles() for the
UltraScale+ PHY, SETTLE_VID_NS = 95 ns for the Versal XPHY), copied below as they were.
Bit for bit: 22 on the KV260 at 912 Mbit/s with a 200 MHz lp clock (107 ns + 24 UI),
0x13 on the Huins build at 1440 Mbit/s (120 ns + 0 UI); the UltraScale+ target gives
settle_cycles() at every lane rate and lp clock, the Versal one 95 ns at 200 MHz for
every lane rate. Skipped without a C compiler.
Run: python3 -m unittest discover -s tools/tests
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CC = shutil.which("cc") or shutil.which("gcc")

HARNESS = r"""
#include <stdio.h>
#include "bow_dphy_rx.h"

/* bow_csi2rx.c before step 4 */
static uint32_t phy_cycles(uint32_t ns, uint32_t mhz) {
  uint32_t n = (ns * mhz + 500u) / 1000u;
  return n < 1u ? 1u : n > 255u ? 255u : n;
}

static uint32_t settle_cycles(uint32_t lane_rate, uint32_t mhz, uint32_t lp_filter) {
  if (lane_rate == 0) return phy_cycles(70, mhz);
  uint64_t ui_ps = 1000000000000ull / lane_rate;
  uint64_t n = ((107000u + 24u * ui_ps) * mhz + 500000u) / 1000000u;
  uint64_t lat = 3u + lp_filter;
  n = n > lat ? n - lat : 1u;
  return n > 255u ? 255u : (uint32_t)n;
}

int main(void) {
  /* the two working points of the boards */
  printf("kv260 %u %u\n", bow_dphy_rx_settle(107, 24, 912000000u, 200, 2),
         settle_cycles(912000000u, 200, 2));
  printf("huins %u %u\n", bow_dphy_rx_settle(120, 0, 1440000000u, 200, 2), phy_cycles(95, 200));
  /* the KV260 simulation: video clock 107.5 MHz, INFO says 108 */
  printf("kv260sim %u %u\n", bow_dphy_rx_settle(107, 24, 912000000u, 108, 2),
         settle_cycles(912000000u, 108, 2));
  /* sweeps: lane rate 0 (unknown) and 80 Mbit/s .. 2.5 Gbit/s, lp clock 50 .. 400 MHz,
   * LP_FILTER 0 .. 15 */
  unsigned bad_xusp = 0, bad_versal = 0, n = 0;
  for (uint32_t mhz = 50; mhz <= 400; mhz += 1) {
    for (uint32_t f = 0; f < 16; f += 5) {
      if (bow_dphy_rx_settle(107, 24, 0, mhz, f) != settle_cycles(0, mhz, f)) bad_xusp++;
      for (uint32_t rate = 80000000u; rate <= 2500000000u; rate += 7000000u) {
        n++;
        if (bow_dphy_rx_settle(107, 24, rate, mhz, f) != settle_cycles(rate, mhz, f)) bad_xusp++;
      }
    }
  }
  for (uint32_t rate = 80000000u; rate <= 2500000000u; rate += 1000000u) {
    if (bow_dphy_rx_settle(120, 0, rate, 200, 2) != phy_cycles(95, 200)) bad_versal++;
  }
  printf("sweep %u %u %u\n", n, bad_xusp, bad_versal);
  return 0;
}
"""


@unittest.skipIf(CC is None, "no C compiler")
class DphySettleTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with tempfile.TemporaryDirectory() as d:
            src = Path(d) / "settle.c"
            exe = Path(d) / "settle"
            src.write_text(HARNESS)
            r = subprocess.run([CC, "-std=gnu11", "-O1", "-Wall", "-Wextra", "-Werror",
                                "-I", str(REPO / "sw/common/include"), str(src), "-o", str(exe)],
                               capture_output=True, text=True, timeout=120, check=False)
            if r.returncode != 0:
                raise AssertionError("harness does not compile:\n" + r.stdout + r.stderr)
            out = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120,
                                 check=True).stdout
        cls.res = {f[0]: [int(x) for x in f[1:]] for f in (ln.split() for ln in out.splitlines())}

    def test_kv260(self):
        """UltraScale+ (KV260): 107 ns + 24 UI gives settle_cycles() = 22 at 912 Mbit/s, 200 MHz."""
        self.assertEqual(self.res["kv260"], [22, 22])
        self.assertEqual(self.res["kv260sim"][0], self.res["kv260sim"][1])

    def test_huins(self):
        """Versal (Huins): 120 ns + 0 UI gives 0x13 = 95 ns at 200 MHz, as SETTLE_VID_NS did."""
        self.assertEqual(self.res["huins"], [0x13, 0x13])

    def test_sweep(self):
        """The UltraScale+ target is settle_cycles() at every rate, lp clock and filter; the
        Versal one is 95 ns at 200 MHz for every rate."""
        n, bad_xusp, bad_versal = self.res["sweep"]
        self.assertGreater(n, 100000)
        self.assertEqual(bad_xusp, 0)
        self.assertEqual(bad_versal, 0)


if __name__ == "__main__":
    unittest.main()
