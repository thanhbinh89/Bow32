#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Print the source files of Bow32 file lists (.f) for xvlog, one per line.

Same rules as `verilator -F` and hw/fpga/common/tcl/filelist.tcl: a path is
relative to the list that contains it, -F/-f nest, // starts a comment.
+incdir+<dir> becomes `-i <dir>`. A file listed twice is printed once.

    flist.py a.f [b.f ...] > files.txt      (then: xvlog -sv -f files.txt)
"""
import os
import sys


def expand(path, out):
    base = os.path.dirname(os.path.abspath(path))
    with open(path) as fh:
        for line in fh:
            line = line.split("//", 1)[0].strip()
            if not line:
                continue
            if line.startswith(("-F ", "-f ")):
                expand(os.path.join(base, line[3:].strip()), out)
                continue
            if line.startswith("+incdir+"):
                item = "-i " + os.path.normpath(os.path.join(base, line[8:]))
            else:
                item = os.path.normpath(os.path.join(base, line))
            if item not in out:
                out.append(item)


def main():
    out = []
    for f in sys.argv[1:]:
        expand(f, out)
    print("\n".join(out))


if __name__ == "__main__":
    main()
