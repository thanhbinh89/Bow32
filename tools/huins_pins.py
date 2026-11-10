#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Write the pin XDC of the Huins MFP-VP1902 target from the board netlist.

The Huins documents are confidential, so the repo holds no FPGA ball number:
hw/fpga/huins_vp1902/constr/pins.txt maps every top-level port to a board
net, and this tool looks the nets up in the netlist workbook of the user's
local copy (docs/fpga/Huins_MFP-VP1902/*NETLIST*.xlsx, sheet "VP1902
Schematic Net List": one row per net, then reference / pin pairs; the FPGA is
U1, its pins are the balls). The output goes to the build directory and must
never be committed.

    python3 tools/huins_pins.py --netlist <xlsx> --pins <pins.txt> \\
        [--card ram|cam] [--site 10] [--clk ref200|site] [--any-site] -o <out.xdc>

pins.txt sections: [all] (every build), [card=<card>] (the top of that card;
"[card=<card> sites=1,10]" also lists the only sites the card is verified on,
another site needs --any-site), [clk=<clk>] (clock input). A file without any
[card=...] section is a single-card map (the default card ram).

Needs openpyxl (only for this target).
"""

import argparse
import re
import sys

SHEET = "VP1902 Schematic Net List"
FPGA_REF = "U1"
DEFAULT_CARD = "ram"

SECTION_RE = re.compile(
    r"\[(?:(all)|clk=([a-z0-9_]+)|card=([a-z0-9_]+)(?:\s+sites=([0-9]+(?:,[0-9]+)*))?)\]")


def parse_pins(path, site, clk, card=DEFAULT_CARD, any_site=False):
    """Return [(port, net)] of the [all], [card=<card>] and [clk=<clk>] sections.

    Refuses a card without a section (except the default card of a map without
    any card section) and a site the card's section does not list (unless
    any_site)."""
    pins = []
    section = None
    card_sites = {}   # card -> verified sites (None: any site)
    with open(path, encoding="utf-8") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("["):
                m = SECTION_RE.fullmatch(line)
                if not m:
                    raise SystemExit(f"{path}:{lineno}: unknown section '{line}'")
                if m.group(1):
                    section = "all"
                elif m.group(2):
                    section = f"clk={m.group(2)}"
                else:
                    section = f"card={m.group(3)}"
                    if m.group(3) in card_sites:
                        raise SystemExit(f"{path}:{lineno}: second [card={m.group(3)}] section")
                    card_sites[m.group(3)] = m.group(4).split(",") if m.group(4) else None
                continue
            fields = line.split()
            if len(fields) != 2:
                raise SystemExit(f"{path}:{lineno}: expected '<port> <net>', got '{line}'")
            if section is None:
                raise SystemExit(f"{path}:{lineno}: pin line before the first [section]")
            if section in ("all", f"clk={clk}", f"card={card}"):
                pins.append((fields[0], fields[1].replace("{site}", str(site))))
    if card not in card_sites and (card_sites or card != DEFAULT_CARD):
        raise SystemExit(f"{path}: no [card={card}] section (cards: "
                         f"{', '.join(sorted(card_sites)) or 'none'})")
    sites = card_sites.get(card)
    if sites is not None and str(site) not in sites and not any_site:
        raise SystemExit(f"{path}: card {card} is only verified on FMC+ site(s) "
                         f"{', '.join(sites)}, not {site} (its top is site specific); "
                         "--any-site writes the pins anyway")
    if not any(port == "clk_p_i" for port, _ in pins):
        raise SystemExit(f"{path}: no clock pins for CLK_SRC '{clk}'")
    return pins


def read_netlist(path):
    """Return {net: [ball, ...]} of the FPGA (U1) from the netlist workbook."""
    try:
        import openpyxl  # noqa: PLC0415 (only this target needs it)
    except ImportError:
        raise SystemExit("error: openpyxl is required (pip install openpyxl)") from None
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    if SHEET not in wb.sheetnames:
        raise SystemExit(f"{path}: no sheet '{SHEET}' (sheets: {', '.join(wb.sheetnames)})")
    balls = {}
    for row in wb[SHEET].iter_rows(values_only=True):
        if not row or row[0] is None:
            continue
        net = str(row[0]).strip()
        rest = row[1:]
        for i in range(0, len(rest) - 1, 2):
            ref, pin = rest[i], rest[i + 1]
            if ref is not None and str(ref).strip() == FPGA_REF and pin is not None:
                balls.setdefault(net, []).append(str(pin).strip())
    wb.close()
    if not balls:
        raise SystemExit(f"{path}: no {FPGA_REF} pins in sheet '{SHEET}'")
    return balls


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    ap.add_argument("--netlist", required=True, help="Huins netlist workbook (.xlsx)")
    ap.add_argument("--pins", required=True, help="port -> net map (constr/pins.txt)")
    ap.add_argument("--card", default=DEFAULT_CARD,
                    help=f"card section of pins.txt: ram, cam ({DEFAULT_CARD})")
    ap.add_argument("--site", default="10", help="FMC+ site number of the net names (10)")
    ap.add_argument("--clk", default="ref200", help="clock source section of pins.txt (ref200)")
    ap.add_argument("--any-site", action="store_true",
                    help="allow a site the card section does not list (unverified)")
    ap.add_argument("-o", "--output", required=True, help="XDC to write")
    args = ap.parse_args(argv)

    if not re.fullmatch(r"[1-4]0?", args.site):
        raise SystemExit(f"error: --site must be 1, 10, 2, 20, 3, 30, 4 or 40, not '{args.site}'")
    if not re.fullmatch(r"[a-z0-9_]+", args.card):
        raise SystemExit(f"error: --card must be a section name such as ram or cam, not '{args.card}'")
    pins = parse_pins(args.pins, args.site, args.clk, args.card, args.any_site)
    balls = read_netlist(args.netlist)

    errors = []
    lines = []
    used = {}
    for port, net in pins:
        found = balls.get(net, [])
        if len(found) != 1:
            # the count only: the balls are confidential, also on a terminal or in a log
            errors.append(f"{port}: net {net} has {len(found)} FPGA pins")
            continue
        ball = found[0]
        if ball in used:
            errors.append(f"{port}: ball of net {net} already used by {used[ball]}")
            continue
        used[ball] = port
        lines.append(f"set_property PACKAGE_PIN {ball:<6} [get_ports {{{port}}}]  ;# {net}")
    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        raise SystemExit(1)

    # (the header of the default card is the one of the single-card tool)
    card = "" if args.card == DEFAULT_CARD else f"card {args.card}, "
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write("# GENERATED by tools/huins_pins.py from the confidential Huins netlist:\n"
                 "# contains FPGA ball numbers, never commit or publish this file.\n"
                 f"# {card}site FMC+{args.site}, clock source {args.clk}, {len(lines)} pins\n")
        fh.write("\n".join(lines) + "\n")
    print(f"huins_pins: {len(lines)} pins ({card}site {args.site}, clock {args.clk}) -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
