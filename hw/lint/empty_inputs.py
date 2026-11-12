#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Inputs connected to nothing.

Lists every input (or inout) port of an instance that is written with an empty
connection, `.name ()`, in the design Verilator elaborates with the given arguments, and
fails when there is one. Verilator itself has no rule for that: PINMISSING (a pin not
written at all) is an error of the lint run (-Werror-PINMISSING), but an empty pin is
PINCONNECTEMPTY, for inputs and outputs alike, which hw/lint/verilator_waivers.vlt waives:
an empty output is the normal no-connect. Verilator's netlist (--xml-only) has the
direction and the connection of every port of every instance.

    empty_inputs.py [--verilator V] [--exclude GLOB ...] -- <Verilator arguments>

The Verilator arguments are those of an elaboration (file lists, files, --top-module,
-G...), run in the current directory; the XML goes to a temporary directory. Instances
written in a file that matches an --exclude glob are skipped (default: the third party
code that verilator_waivers.vlt does not lint either). Used by `make -C sim lint` for the
system testbench (its instances and every instance of the design below it).
"""
import argparse
import fnmatch
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

DEFAULT_EXCLUDE = ["*/lowrisc_ibex/*", "*/ip/ddr/litedram/generated/*"]


def empty_inputs(xml_file, exclude):
    """[(file, line, instance, module, port)] of the inputs connected to nothing."""
    root = ET.parse(xml_file).getroot()
    files = {f.get("id"): f.get("filename") for f in root.iter("file")}
    found = []
    for inst in root.iter("instance"):
        for port in inst.findall("port"):
            if port.get("direction") not in ("in", "inout") or len(list(port)) != 0:
                continue
            fid, line = port.get("loc", "?,0").split(",")[:2]
            fname = files.get(fid, fid)
            if any(fnmatch.fnmatch(fname, g) for g in exclude):
                continue
            found.append((fname, int(line), inst.get("name"), inst.get("defName"),
                          port.get("name")))
    return sorted(set(found))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verilator", default=os.environ.get("VERILATOR", "verilator"))
    ap.add_argument("--exclude", action="append", default=None,
                    help="skip instances written in files matching this glob")
    ap.add_argument("vargs", nargs=argparse.REMAINDER)
    args = ap.parse_args()
    vargs = args.vargs[1:] if args.vargs[:1] == ["--"] else args.vargs
    exclude = DEFAULT_EXCLUDE if args.exclude is None else args.exclude
    with tempfile.TemporaryDirectory() as tmp:
        xml_file = os.path.join(tmp, "netlist.xml")
        cmd = [args.verilator, "--xml-only", "--xml-output", xml_file, "-Mdir", tmp, *vargs]
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        if r.returncode != 0 or not os.path.exists(xml_file):
            sys.stdout.write(r.stdout)
            print("empty_inputs: Verilator failed")
            return 2
        found = empty_inputs(xml_file, exclude)
    for fname, line, inst, mod, port in found:
        print(f"{fname}:{line}: instance {inst} ({mod}): input {port} connected to nothing")
    top = next((a for i, a in enumerate(vargs) if i and vargs[i - 1] == "--top-module"), "?")
    print(f"empty_inputs: {top}: {len(found)} inputs connected to nothing")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
