#!/usr/bin/env python3
# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Bow32 MPS4 tool - puts a Bow32 build on the configuration microSD card of an
Arm MPS4 board and (re)starts the board through its MCC console
(docs/ddr_mps4.md).

The board controller (MCC) shows the microSD card to the PC as a USB drive
(label M1SDP) and has a serial console on port 0 of the FT4232H of the USB-C
debug port; Bow32's UART0 is port 1. The card is shared with other designs:
only MB/HBI0376B/board.txt (its APPFILE line) and the directory
MB/HBI0376B/BOW32/ are written, config.txt is never touched.

Examples:
  bow32_mps4.py deploy                 install + reboot + show the Bow32 console
  bow32_mps4.py install [SDCARD_DIR]   copy BOW32/ to the card, APPFILE -> BOW32
  bow32_mps4.py reboot                 MCC REBOOT: program the FPGA from the card (~60 s)
  bow32_mps4.py reset                  MCC RESET: restart Bow32 only (CB_nRST, ~1 s)
  bow32_mps4.py restore                give the card back to the design it had before
  bow32_mps4.py show                   card content, board.txt and config.txt

SDCARD_DIR is the sdcard/ directory of a build (default build/fpga/mps4/sdcard).
The card is mounted with `mount MNT` and unmounted with `umount MNT` (needs an
fstab entry with the 'user' option, see docs/ddr_mps4.md); with --no-mount MNT
is used as it is and left mounted. The serial ports are found in
/dev/serial/by-id (FT4232H "FTDI_USB__-__Serial_Converter_<serial>") unless
--mcc / --console name them.

Every install that finds board.txt selecting another design keeps that
board.txt as MB/HBI0376B/BOW32/board.txt.orig on the card itself (plus a copy
in ~/.local/state/bow32/mps4/), so the kept copy follows the other team's
latest edits. While the card selects BOW32, `restore` sets only the APPFILE
line back from it (their other lines stay as they are now); a card that
selects another design is left alone; a damaged board.txt (no APPFILE line,
or several with one selecting BOW32) gets the card's whole kept file, after
the damaged one is saved as BOW32/board.txt.damaged; several APPFILE lines
none of which selects BOW32 are left alone. restore never selects a file that
is not on the card. Each file is written as NAME.new (in BOW32/), synced and
renamed over NAME, and board.txt is edited last: a failure half way leaves
the card booting what it booted before (a failure exactly between the
renames of bow32.bit and bow32.txt leaves the new bitstream with the old
bow32.txt: install again). Read-only files are not replaced.

Needs pyserial for reboot, reset and deploy.
"""

import argparse
import filecmp
import glob
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

try:
    import serial
except ImportError:  # only reboot / reset / deploy need it
    serial = None

REPO = Path(__file__).resolve().parent.parent
HBI = Path("MB") / "HBI0376B"
APPFILE = "BOW32\\bow32.txt"
FILES = ("bow32.bit", "bow32.txt")
BACKUP = "board.txt.orig"
STATE_DIR = Path.home() / ".local" / "state" / "bow32" / "mps4"
FTDI_GLOB = "/dev/serial/by-id/usb-FTDI_USB__-__Serial_Converter_*-if0{}-port0"
APPFILE_RE = re.compile(r"(?m)^(APPFILE:[ \t]*)([^\s;]+)")   # ";" starts a comment anywhere
DAMAGED = "board.txt.damaged"


class Mps4Error(Exception):
    pass


def say(msg):
    print(msg)


# ------------------------------------------------------------------ board.txt
def appfiles(text):
    """Values of the APPFILE lines of board.txt text (the MCC wants exactly one)."""
    return [m[1] for m in APPFILE_RE.findall(text)]


def get_appfile(text):
    found = appfiles(text)
    if len(found) != 1:
        raise Mps4Error(f"board.txt: expected one APPFILE line, found {len(found)}")
    return found[0]


def set_appfile(text, value):
    """board.txt text with APPFILE = value: the rest of the line (comment) and
    the line endings (the MCC wants CRLF) stay as they are."""
    get_appfile(text)
    return APPFILE_RE.sub(lambda m: m.group(1) + value, text)   # a function: no escapes


def selects_bow32(appfile):
    # FAT names, and so the MCC, ignore case: bow32\BOW32.TXT is this design too
    return appfile.upper() == APPFILE.upper()


def read_text(path):
    return path.read_bytes().decode("latin-1")


# --------------------------------------------------------- whole-file writes
def discard(path):
    """Remove a temporary file, best effort: the card may be gone already."""
    try:
        path.unlink()
    except OSError:
        pass


def stage(path, fill, tmp_dir=None):
    """Write NAME.new through fill(file) and fsync it, so it is on the card
    before it replaces anything. In tmp_dir (default: PATH's directory; the
    same card, os.replace() needs one file system), so that a temporary file
    of board.txt lives in BOW32/, never in the other team's folder. Returns
    the temporary path; it is removed again if this fails."""
    tmp = Path(tmp_dir or path.parent) / (path.name + ".new")
    try:
        with open(tmp, "wb") as f:
            fill(f)
            f.flush()
            os.fsync(f.fileno())
    except BaseException:   # Ctrl-C too: no half written PATH.new left behind
        discard(tmp)
        raise
    return tmp


def refuse_read_only(path):
    """vfat shows the FAT read-only attribute as a mode without write bits;
    the mode, not os.access(), also holds when the tool runs as root."""
    if path.exists() and not path.stat().st_mode & 0o222:
        raise Mps4Error(f"{path} is read-only: not replaced")


def write_bytes(path, data, tmp_dir=None):
    """Replace PATH whole or not at all: an interrupted write (card full or
    pulled, Ctrl-C) leaves the old file, never an empty or short board.txt
    that no design boots from. A read-only file is refused: the rename would
    replace it (and drop its protection) where an in-place write would fail."""
    refuse_read_only(path)
    tmp = stage(path, lambda f: f.write(data), tmp_dir)
    try:
        os.replace(tmp, path)
    except BaseException:
        discard(tmp)
        raise


def write_text(path, text, tmp_dir=None):
    write_bytes(path, text.encode("latin-1"), tmp_dir)


# ----------------------------------------------------------------------- card
class Card:
    """The mounted card: `with Card(mnt, mount) as root:` mounts MNT if needed
    and unmounts it at the end (the MCC must not see a half written card).
    When the block fails, `state` says what board.txt selects afterwards (read
    back before the umount) for the error message."""

    def __init__(self, mnt, mount=True, log=say):
        self.mnt, self.mount, self.log = Path(mnt), mount, log
        self.board = self.mnt / HBI / "board.txt"
        self.before = self.state = None

    def __enter__(self):
        mounted = False
        if self.mount and not os.path.ismount(self.mnt):
            run(["mount", str(self.mnt)])
            mounted = True
        try:
            if not self.board.is_file():
                raise Mps4Error(f"{self.board} not found: not the MPS4 card, "
                                "or not mounted (fstab entry, see docs/ddr_mps4.md)")
            self.before = self.board.read_bytes()
        except BaseException:
            if mounted:   # __exit__ does not run: do not leave a foreign drive mounted
                self.umount(failing=True)
            raise
        return self.mnt

    def __exit__(self, exc_type, exc, tb):
        if exc_type is not None:
            self.state = self.describe()
        os.sync()
        if self.mount and os.path.ismount(self.mnt):
            self.umount(failing=exc_type is not None)
        return False

    def umount(self, failing):
        """umount MNT. While another error is on its way out, a umount failure
        is only reported: that error is the one the user must see."""
        try:
            run(["umount", str(self.mnt)])
        except (Mps4Error, OSError) as e:
            if not failing:
                raise
            self.log(f"warning: {e}: {self.mnt} is still mounted, unmount it before "
                     "the MCC uses the card")
            return
        self.log(f"{self.mnt}: unmounted")

    def describe(self):
        """What board.txt selects now, and whether this run changed it."""
        try:
            now = self.board.read_bytes()
        except OSError as e:
            return f"card: board.txt cannot be read back ({e}), its state is unknown"
        change = "not changed" if now == self.before else "changed"
        found = appfiles(now.decode("latin-1"))
        if len(found) != 1:
            return f"card: board.txt {change}, {len(found)} APPFILE lines (the MCC wants one)"
        state = f"card: board.txt {change}, APPFILE {found[0]}"
        if selects_bow32(found[0]):   # every file is replaced whole, see install()
            state += " (BOW32 files: new where 'copied' is printed above, else the previous ones)"
        return state


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise Mps4Error(f"{' '.join(cmd)}: {(r.stderr or r.stdout).strip()}")


def keep_board(text, old, dst, state_dir, log):
    """Keep board.txt for `restore` (on the card and on the host) while it
    selects another design. Taken again at every such install, so the copy
    follows that team's latest edits; while the card selects BOW32 the copy
    kept earlier is still theirs and stays."""
    if selects_bow32(old):
        if not (dst / BACKUP).is_file():
            host = state_dir / BACKUP
            then = f"`restore` will use {host}" if host.is_file() else "`restore` will need --appfile"
            log(f"warning: board.txt already selects {old} and the card has no {BACKUP}: {then}")
        return
    data = text.encode("latin-1")
    write_bytes(dst / BACKUP, data)
    state_dir.mkdir(parents=True, exist_ok=True)
    write_bytes(state_dir / BACKUP, data)
    log(f"kept the card's board.txt (APPFILE {old}) as {HBI / 'BOW32' / BACKUP} "
        f"and {state_dir / BACKUP}")


def drop_cache(path):
    """Best effort: drop the clean cached pages of a synced file, so reading it
    back reads the card."""
    try:
        fd = os.open(path, os.O_RDONLY)
        try:
            os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        finally:
            os.close(fd)
    except (OSError, AttributeError):
        pass


def copy_build(src, dst, log):
    """Stage every file of the build as NAME.new on the card and check that it
    reads back the same before any is renamed over the previous one: a copy
    that fails (card full or pulled, Ctrl-C) leaves the previous build whole.
    The two renames are separate steps: a failure exactly between them leaves
    the new bow32.bit with the previous bow32.txt (install again)."""
    for f in FILES:
        refuse_read_only(dst / f)
    staged = {}
    try:
        for f in FILES:
            with open(src / f, "rb") as fi:
                staged[f] = stage(dst / f, lambda fo: shutil.copyfileobj(fi, fo))
            drop_cache(staged[f])   # compare what the card holds, not the page cache
            if not filecmp.cmp(src / f, staged[f], shallow=False):
                raise Mps4Error(f"{staged[f]}: read back differs from {src / f}")
        for f in FILES:
            os.replace(staged[f], dst / f)
            del staged[f]
            log(f"copied {HBI / 'BOW32' / f} ({(dst / f).stat().st_size} bytes, verified)")
    finally:
        for tmp in staged.values():
            discard(tmp)


def install(root, sd_dir, state_dir=None, log=say):
    """Copy BOW32/{bow32.bit, bow32.txt} of a build to the card and point
    APPFILE at it. board.txt is edited last, after the files are in place:
    a failure leaves the card booting what it booted before."""
    state_dir = Path(state_dir or STATE_DIR)   # at call time, so a patched STATE_DIR counts
    src = Path(sd_dir) / HBI / "BOW32"
    for f in FILES:
        if not (src / f).is_file():
            raise Mps4Error(f"{src / f} not found (run `make fpga BOARD=mps4` first)")
    hbi = Path(root) / HBI
    board = hbi / "board.txt"
    text = read_text(board)
    old = get_appfile(text)
    dst = hbi / "BOW32"
    dst.mkdir(exist_ok=True)
    keep_board(text, old, dst, state_dir, log)
    copy_build(src, dst, log)
    if old != APPFILE:
        write_text(board, set_appfile(text, APPFILE), dst)
    log(f"board.txt: APPFILE {old} -> {APPFILE}")


def find_kept(hbi, state_dir, fix, host=True):
    """(path, text, APPFILE) of the board.txt kept by install: the card's copy
    first, then (host) the host's. `fix` tells the user what to do without one."""
    for path in (hbi / "BOW32" / BACKUP,) + ((state_dir / BACKUP,) if host else ()):
        if path.is_file():
            text = read_text(path)
            found = appfiles(text)
            if len(found) != 1 or selects_bow32(found[0]):
                raise Mps4Error(f"{path} does not select another design "
                                f"(APPFILE: {', '.join(found) or 'none'}): {fix}")
            return path, text, found[0]
    where = "on the card" + (f" or in {state_dir}" if host else "")
    raise Mps4Error(f"no {BACKUP} {where}: {fix}")


def appfile_on_card(hbi, value):
    """The file an APPFILE value names (relative to MB/HBI0376B, '\\'
    separators, any case as on FAT), or None."""
    path = hbi
    for part in value.replace("\\", "/").split("/"):
        if not part or not path.is_dir():
            return None
        same = [c for c in path.iterdir() if c.name.lower() == part.lower()]
        if not same:
            return None
        path = same[0]
    return path if path.is_file() else None


def need_on_card(hbi, value, what):
    """restore never makes the card select a file it does not hold: the MCC
    would boot no design at all."""
    if appfile_on_card(hbi, value) is None:
        raise Mps4Error(f"{what} {value!r} is not a file under {HBI} on the card: nothing "
                        "written (in a shell, quote values with a backslash: 'CA5DS\\ca5ds.txt')")


def set_board_appfile(board, text, old, appfile, log):
    """restore --appfile: set the APPFILE line, nothing else."""
    if not re.fullmatch(r"[!-:<-~]+", appfile):   # printable ASCII without ' ' and ';'
        raise Mps4Error(f"--appfile {appfile!r}: one word without spaces or ';' (ASCII), "
                        "e.g. 'CA5DS\\ca5ds.txt'")
    if selects_bow32(appfile):
        raise Mps4Error("--appfile selects BOW32: use `install`, which keeps the other "
                        "team's board.txt first")
    if old is None:
        raise Mps4Error(f"{board} is damaged (no single APPFILE line): repair it by hand, or "
                        f"run `restore` without --appfile when one of its APPFILE lines selects "
                        f"BOW32 and the card has its {BACKUP}")
    need_on_card(board.parent, appfile, "--appfile")
    write_text(board, set_appfile(text, appfile), board.parent / "BOW32")
    log(f"board.txt: APPFILE {old} -> {appfile}")


def restore(root, appfile=None, state_dir=None, log=say):
    """Give the card back to the design install found on it. While board.txt
    selects BOW32 only its APPFILE line is set from the kept copy, so edits
    the other team made since stay; a card that selects another design is
    left alone; a board.txt without one APPFILE line (damaged) gets the whole
    kept copy of the card (the damaged file saved as BOW32/board.txt.damaged
    first); several APPFILE lines none of which selects BOW32 are not Bow32's
    doing and are left alone. With appfile: only set APPFILE to it."""
    state_dir = Path(state_dir or STATE_DIR)
    hbi = Path(root) / HBI
    board = hbi / "board.txt"
    text = read_text(board)
    found = appfiles(text)
    old = found[0] if len(found) == 1 else None
    if appfile is not None:
        set_board_appfile(board, text, old, appfile, log)
        return
    if old is not None and not selects_bow32(old):
        log(f"card does not select BOW32 (APPFILE {old}): nothing to restore")
        return
    if old is None and found and not any(selects_bow32(v) for v in found):
        log(f"board.txt has {len(found)} APPFILE lines, none selects BOW32: nothing to "
            "restore (not written by this tool; repair it by hand)")
        return
    if old is None:
        path, kept, value = find_kept(hbi, state_dir, "repair board.txt by hand (a copy of an "
                                      f"earlier session may be {state_dir / BACKUP})", host=False)
        need_on_card(hbi, value, f"the APPFILE of {path}")
        write_bytes(hbi / "BOW32" / DAMAGED, text.encode("latin-1"))
        write_text(board, kept, hbi / "BOW32")
        log(f"board.txt had {len(found)} APPFILE lines: saved as {HBI / 'BOW32' / DAMAGED}, "
            f"replaced by {path} (APPFILE {value})")
        return
    path, kept, value = find_kept(hbi, state_dir, "use --appfile")
    need_on_card(hbi, value, f"the APPFILE of {path}")
    (hbi / "BOW32").mkdir(exist_ok=True)
    write_text(board, set_appfile(text, value), hbi / "BOW32")
    log(f"board.txt: APPFILE {old} -> {value} (from {path})")


def show(root, log=say):
    root = Path(root)
    for p in sorted((root / "MB").rglob("*")):
        if p.is_file():
            log(f"{p.stat().st_size:>11}  {p.relative_to(root)}")
    for name in (HBI / "board.txt", Path("config.txt")):
        if (root / name).is_file():
            log(f"--- {name}")
            log(read_text(root / name).replace("\r", "").rstrip())


# --------------------------------------------------------------- MCC console
def find_port(index, given=None):
    """Port <index> of the MPS4's FT4232H (0 = MCC console, 1 = Bow32 UART0)."""
    if given:
        return given
    ports = sorted(glob.glob(FTDI_GLOB.format(index)))
    if len(ports) != 1:
        raise Mps4Error(f"found {len(ports)} candidate ports for FT4232H port {index} "
                        f"({', '.join(ports) or 'none'}): use --mcc / --console")
    return ports[0]


def open_port(name, opener, timeout_s=60.0):
    """Open a serial port, waiting for it to come back (the MCC disables the
    debug USB while it reboots)."""
    end = time.monotonic() + timeout_s
    while True:
        try:
            return opener(name)
        except (OSError, ValueError) as e:
            if time.monotonic() > end:
                raise Mps4Error(f"{name}: {e}")
            time.sleep(0.5)


def serial_opener(name):
    if serial is None:
        raise Mps4Error("pyserial is required (pip install pyserial)")
    return serial.Serial(name, 115200, timeout=0.05)


PROGRESS_RE = re.compile(r"Address: 0x[0-9A-Fa-f]{8}")


def watch(mcc, console, done, timeout_s, settle_s, log):
    """Read both ports until the MCC text contains `done`, then settle_s more
    seconds of console. Returns (mcc_text, console_text); MCC lines go to log.
    The FPGA programming progress ("\rAddress: 0x00040000\r..." on one line,
    one entry per 256 KiB) is counted, not printed."""
    mcc_text, con, pending, steps = "", b"", "", 0
    end = time.monotonic() + timeout_s
    stop = None
    while True:
        now = time.monotonic()
        if stop is not None and now >= stop:
            break
        if stop is None and now >= end:
            raise Mps4Error(f"MCC: no '{done}' within {timeout_s:.0f} s")
        d = mcc.read(4096).decode("latin-1").replace("\r\n", "\n").replace("\r", "\n")
        con += console.read(4096)
        if d:
            mcc_text += d
            pending += d
            while "\n" in pending:
                line, pending = pending.split("\n", 1)
                steps += len(PROGRESS_RE.findall(line))
                line = PROGRESS_RE.sub("", line).strip()
                if line:
                    if steps:
                        log(f"MCC: ({steps} x 256 KiB programmed)")
                        steps = 0
                    log(f"MCC: {line}")
        if stop is None and done in mcc_text:
            stop = time.monotonic() + settle_s
    return mcc_text, con.decode("latin-1").replace("\r", "")


def mcc_reboot(mcc_port, console_port, opener=serial_opener, timeout_s=240.0,
               settle_s=5.0, log=say):
    """REBOOT: the MCC power-cycles the board, programs the FPGA from the card
    and releases the resets. Returns the Bow32 console text after that."""
    mcc = open_port(mcc_port, opener)
    mcc.write(b"\r")
    time.sleep(0.3)
    mcc.write(b"REBOOT\r")
    time.sleep(1.0)
    mcc.close()
    time.sleep(3.0)
    mcc, con = open_port(mcc_port, opener), open_port(console_port, opener)
    text, out = watch(mcc, con, "Releasing CB_nRST", timeout_s, settle_s, log)
    if "FPGA configuration complete" not in text:
        raise Mps4Error("the MCC did not report 'FPGA configuration complete' "
                        "(see its lines above; the FPGA may hold no design)")
    return out


def mcc_reset(mcc_port, console_port, opener=serial_opener, settle_s=3.0, log=say):
    """RESET: the MCC pulses CB_nRST, Bow32 restarts (no FPGA programming)."""
    mcc, con = open_port(mcc_port, opener), open_port(console_port, opener)
    mcc.write(b"\r")
    time.sleep(0.3)
    mcc.read(4096)
    con.read(4096)
    mcc.write(b"RESET\r")
    return watch(mcc, con, "Resets released", 20.0, settle_s, log)[1]


# ----------------------------------------------------------------------- main
def main(argv=None, opener=serial_opener):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--mnt", default="/mnt/mps4", help="mount point of the card (default /mnt/mps4)")
    ap.add_argument("--no-mount", action="store_true", help="the card is already at --mnt: no mount / umount")
    ap.add_argument("--mcc", help="MCC console port (default: FT4232H port 0 in /dev/serial/by-id)")
    ap.add_argument("--console", help="Bow32 UART0 port (default: FT4232H port 1)")
    ap.add_argument("--settle", type=float, default=5.0,
                    help="seconds of Bow32 console shown after the reset release (default 5)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("install", "deploy"):
        p = sub.add_parser(name, help="copy a build to the card" + (" and reboot" if name == "deploy" else ""))
        p.add_argument("sdcard", nargs="?", default=str(REPO / "build" / "fpga" / "mps4" / "sdcard"),
                       help="sdcard/ directory of the build (default build/fpga/mps4/sdcard)")
    sub.add_parser("reboot", help="MCC REBOOT: program the FPGA from the card")
    sub.add_parser("reset", help="MCC RESET: restart Bow32 only")
    p = sub.add_parser("restore", help="give the card back to the design it had before install")
    p.add_argument("--appfile", help=r"only set APPFILE to this value (e.g. 'CA5DS\ca5ds.txt')")
    sub.add_parser("show", help="card content, board.txt, config.txt")
    args = ap.parse_args(argv)

    def interrupt(signum, frame):
        raise KeyboardInterrupt
    for sig in (signal.SIGTERM, signal.SIGHUP):   # kill / closed terminal: clean up like Ctrl-C
        try:
            signal.signal(sig, interrupt)
        except (ValueError, OSError):   # not the main thread (tests)
            pass

    card = Card(args.mnt, not args.no_mount)
    try:
        if args.cmd in ("install", "deploy"):
            with card as root:
                install(root, args.sdcard)
        elif args.cmd == "restore":
            with card as root:
                restore(root, args.appfile)
        elif args.cmd == "show":
            with card as root:
                show(root)
        if args.cmd in ("deploy", "reboot", "reset"):
            mcc, con = find_port(0, args.mcc), find_port(1, args.console)
            if args.cmd == "reset":
                out = mcc_reset(mcc, con, opener, settle_s=args.settle)
            else:
                out = mcc_reboot(mcc, con, opener, settle_s=args.settle)
            print(f"--- Bow32 console ({con})")
            print(out.strip() or "(nothing: check the UART pins / UARTMODE, docs/ddr_mps4.md)")
    except (Mps4Error, OSError, KeyboardInterrupt) as e:
        # OSError: card full or pulled, serial port gone. No traceback: what
        # failed, then what the card selects now (the user decides what next).
        print(f"error: {'interrupted' if isinstance(e, KeyboardInterrupt) else e}", file=sys.stderr)
        if card.state:
            print(card.state, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
