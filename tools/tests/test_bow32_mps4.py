# Copyright Bow32 contributors.
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tools/bow32_mps4.py: board.txt editing, install / restore on
a card directory (the kept board.txt, writes that fail half way), mount /
umount handling, and the MCC console dialogue against a fake board.
Run: python3 -m unittest discover tools/tests

No test may reach the user's ~/.local/state/bow32, run mount / umount or
open a serial port: setUpModule points STATE_DIR at a temporary directory
and replaces run() by one that fails (FakeMount stands in for mount /
umount), and main() gets a fake opener.
"""

import errno
import io
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bow32_mps4 as m  # noqa: E402

BOARD_TXT = (b"BOARD: HBI0376B\r\nTITLE: Motherboard configuration file\r\n\r\n[MCCS]\r\n"
             b"MBBIOS: mbb_v211.ebf          ;MB BIOS IMAGE\r\n\r\n[APPLICATION NOTE]            ;Please select\r\n"
             b"APPFILE: CA5DS\\ca5ds.txt      ;Cortex A5 Designstart FPGA\r\n\r\n")
# the other team's board.txt after they edited it between two Bow32 sessions
THEIRS = BOARD_TXT.replace(b"mbb_v211", b"mbb_v300").replace(b"CA5DS\\ca5ds.txt", b"FU4\\fu4.txt")
SELECTS_BOW32 = BOARD_TXT.replace(b"CA5DS\\ca5ds.txt", b"BOW32\\bow32.txt")
CONFIG_TXT = b"[CONFIGURATION]\r\nUARTMODE: 0                 ;0-MCC:FPGA0\r\nFMC_FORCE: 1V2\r\n"
BANNER = (b"\r\nBow32 boot ROM v1.0.0  chip b0320100  clk 50000000 Hz  rst 1\r\n"
          b"ddr: Bow32 DDR2 x8 (LiteDRAM controller), PHY loopback\r\n> ")
REAL_RUN = m.run   # setUpModule replaces m.run


def no_run(cmd):
    raise AssertionError(f"a test ran {cmd}: use FakeMount")


def no_port(name):
    raise AssertionError(f"a test opened the serial port {name}: pass a fake opener")


def setUpModule():
    tmp = tempfile.TemporaryDirectory()
    unittest.addModuleCleanup(tmp.cleanup)
    for patch in (mock.patch.object(m, "STATE_DIR", Path(tmp.name) / "state"),
                  mock.patch.object(m, "run", no_run),
                  mock.patch.object(m.os, "sync")):   # no sync of every disk of the host
        patch.start()
        unittest.addModuleCleanup(patch.stop)


# the other team's designs (and an arbitrary one): restore only selects files on the card
DESIGNS = ("CA5DS/ca5ds.txt", "FU4/fu4.txt", "X/y.txt")


def make_card(root, board=BOARD_TXT):
    hbi = Path(root) / m.HBI
    hbi.mkdir(parents=True)
    (hbi / "board.txt").write_bytes(board)
    (Path(root) / "config.txt").write_bytes(CONFIG_TXT)
    for design in DESIGNS:
        (hbi / design).parent.mkdir(exist_ok=True)
        (hbi / design).write_bytes(b"F0FILE: x.bit\r\n")


def make_build(root, bit=b"BIT1"):
    src = Path(root) / m.HBI / "BOW32"
    src.mkdir(parents=True, exist_ok=True)
    (src / "bow32.bit").write_bytes(bit)
    (src / "bow32.txt").write_bytes(b"F0FILE: bow32.bit\r\n")


def failing_copy(name, exc):
    """shutil.copyfileobj that writes half of the file staged for `name` and
    then raises exc: a full card (OSError) or Ctrl-C (KeyboardInterrupt)."""
    real = shutil.copyfileobj

    def copy(fi, fo, *args):
        if Path(fo.name).name != name + ".new":
            return real(fi, fo, *args)
        data = fi.read()
        fo.write(data[:len(data) // 2])
        raise exc
    return mock.patch.object(m.shutil, "copyfileobj", copy)


class FakeMount:
    """mount / umount of the card (run() and os.path.ismount), `busy` makes
    umount fail like a shell sitting in the mount point."""

    def __init__(self, mounted=False, busy=False):
        self.mounted, self.busy, self.cmds = mounted, busy, []

    def run(self, cmd):
        self.cmds.append(cmd[0])
        if cmd[0] == "umount" and self.busy:
            raise m.Mps4Error(f"umount {cmd[1]}: target is busy")
        self.mounted = cmd[0] == "mount"

    def __enter__(self):
        self.patches = [mock.patch.object(m, "run", self.run),
                        mock.patch.object(m.os.path, "ismount", lambda p: self.mounted)]
        for p in self.patches:
            p.start()
        return self

    def __exit__(self, *exc):
        for p in reversed(self.patches):
            p.stop()


class AppfileTest(unittest.TestCase):
    def test_set_keeps_comment_and_crlf(self):
        text = BOARD_TXT.decode("latin-1")
        out = m.set_appfile(text, m.APPFILE)
        self.assertIn("APPFILE: BOW32\\bow32.txt      ;Cortex A5 Designstart FPGA\r\n", out)
        self.assertEqual(m.get_appfile(out), "BOW32\\bow32.txt")
        self.assertEqual(out.count("\r\n"), text.count("\r\n"))
        self.assertEqual(out.replace("BOW32\\bow32.txt", "CA5DS\\ca5ds.txt"), text)

    def test_one_appfile_line_needed(self):
        with self.assertRaises(m.Mps4Error):
            m.get_appfile("BOARD: X\r\n")
        with self.assertRaises(m.Mps4Error):
            m.set_appfile("APPFILE: a\r\nAPPFILE: b\r\n", "c")

    def test_selects_bow32_ignores_case(self):
        self.assertTrue(m.selects_bow32("bow32\\BOW32.TXT"))
        self.assertFalse(m.selects_bow32("CA5DS\\ca5ds.txt"))


class Tmp(unittest.TestCase):
    """A card, a build and a host state directory in a temporary directory."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.card, self.build, self.state = t / "card", t / "build", t / "state"
        make_card(self.card)
        make_build(self.build)
        self.hbi = self.card / m.HBI
        self.log = []

    def tearDown(self):
        self.tmp.cleanup()

    def install(self):
        m.install(self.card, self.build, self.state, log=self.log.append)

    def restore(self, appfile=None):
        m.restore(self.card, appfile, state_dir=self.state, log=self.log.append)

    def board(self):
        return (self.hbi / "board.txt").read_bytes()

    def set_board(self, data):
        (self.hbi / "board.txt").write_bytes(data)

    def kept(self):
        return (self.hbi / "BOW32" / m.BACKUP).read_bytes(), (self.state / m.BACKUP).read_bytes()

    def bit(self):
        return (self.hbi / "BOW32" / "bow32.bit").read_bytes()

    def leftovers(self):
        return sorted(str(p) for p in Path(self.tmp.name).rglob("*.new"))

    def logged(self, text):
        return any(text in line for line in self.log)

    def main(self, *args, mount=False, mnt=None, opener=no_port):
        """main() on the card, STATE_DIR = self.state; returns (exit code,
        stdout, stderr)."""
        argv = (["--mnt", str(mnt or self.card)] + ([] if mount else ["--no-mount"])
                + [str(a) for a in args])
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err), mock.patch.object(m, "STATE_DIR", self.state):
            try:
                rc = m.main(argv, opener)
            except KeyboardInterrupt:   # escaping, it would stop the whole test run
                self.fail("main() let KeyboardInterrupt escape")
        return rc, out.getvalue(), err.getvalue()


class InstallRestoreTest(Tmp):
    def test_install_restore(self):
        self.install()
        self.assertEqual(self.bit(), b"BIT1")
        self.assertEqual(self.kept(), (BOARD_TXT, BOARD_TXT))
        self.assertEqual(m.get_appfile(m.read_text(self.hbi / "board.txt")), m.APPFILE)
        self.assertEqual((self.card / "config.txt").read_bytes(), CONFIG_TXT)
        # a second install keeps their board.txt, not the one that selects BOW32
        make_build(self.build, b"BIT2")
        self.install()
        self.assertEqual(self.bit(), b"BIT2")
        self.assertEqual(self.kept(), (BOARD_TXT, BOARD_TXT))
        self.restore()
        self.assertEqual(self.board(), BOARD_TXT)
        self.assertEqual((self.card / "config.txt").read_bytes(), CONFIG_TXT)
        self.assertEqual(self.leftovers(), [])

    def test_kept_copy_follows_the_other_team(self):
        # session 1, then they move to FU4 and a new MB BIOS, then session 2
        self.install()
        self.restore()
        self.set_board(THEIRS)
        self.install()
        self.assertEqual(self.kept(), (THEIRS, THEIRS))
        self.restore()
        self.assertEqual(self.board(), THEIRS)

    def test_restore_sets_only_the_appfile_line(self):
        # they edit MBBIOS while the card selects BOW32: restore keeps that edit
        self.install()
        self.set_board(self.board().replace(b"mbb_v211", b"mbb_v212"))
        self.install()
        self.assertEqual(self.kept(), (BOARD_TXT, BOARD_TXT))
        self.restore()
        self.assertEqual(self.board(), BOARD_TXT.replace(b"mbb_v211", b"mbb_v212"))
        self.assertIn(f"board.txt: APPFILE {m.APPFILE} -> CA5DS\\ca5ds.txt "
                      f"(from {self.hbi / 'BOW32' / m.BACKUP})", self.log)

    def test_restore_leaves_another_design_alone(self):
        self.install()
        self.restore()
        self.set_board(THEIRS)
        self.restore()
        self.assertEqual(self.board(), THEIRS)
        self.assertIn("card does not select BOW32 (APPFILE FU4\\fu4.txt): nothing to restore", self.log)
        # also on a card Bow32 never used: nothing kept, nothing needed
        shutil.rmtree(self.hbi / "BOW32")
        shutil.rmtree(self.state)
        rc, out, err = self.main("restore")
        self.assertEqual((rc, err), (0, ""))
        self.assertIn("nothing to restore", out)
        self.assertEqual(self.board(), THEIRS)

    def test_restore_from_host_copy(self):
        self.install()
        (self.hbi / "BOW32" / m.BACKUP).unlink()
        self.restore()
        self.assertEqual(self.board(), BOARD_TXT)

    def test_restore_without_kept_copy_needs_appfile(self):
        self.set_board(SELECTS_BOW32)
        with self.assertRaisesRegex(m.Mps4Error, "use --appfile"):
            self.restore()
        self.assertEqual(self.board(), SELECTS_BOW32)

    def test_restore_refuses_a_kept_copy_that_selects_bow32(self):
        self.install()
        (self.hbi / "BOW32" / m.BACKUP).write_bytes(SELECTS_BOW32)
        with self.assertRaisesRegex(m.Mps4Error, "does not select another design"):
            self.restore()
        self.assertEqual(m.get_appfile(m.read_text(self.hbi / "board.txt")), m.APPFILE)

    def test_restore_damaged_board_txt(self):
        self.install()
        for damaged in (b"", BOARD_TXT[:60], SELECTS_BOW32 + b"APPFILE: X\\x.txt\r\n"):
            with self.subTest(damaged=damaged[-20:]):
                self.set_board(damaged)
                rc, out, err = self.main("restore")
                self.assertEqual((rc, err), (0, ""))
                self.assertEqual(self.board(), BOARD_TXT)
                self.assertIn("replaced by", out)
                # the damaged file is kept next to Bow32's files, never lost
                self.assertEqual((self.hbi / "BOW32" / m.DAMAGED).read_bytes(), damaged)

    def test_restore_leaves_several_foreign_appfile_lines_alone(self):
        self.install()
        theirs = BOARD_TXT + b"APPFILE: FU4\\fu4.txt\r\n"
        self.set_board(theirs)
        rc, out, err = self.main("restore")
        self.assertEqual((rc, err), (0, ""))
        self.assertIn("none selects BOW32: nothing to restore", out)
        self.assertEqual(self.board(), theirs)

    def test_restore_damaged_board_txt_uses_only_the_cards_copy(self):
        self.install()
        (self.hbi / "BOW32" / m.BACKUP).unlink()     # only the host copy is left
        self.set_board(b"")
        with self.assertRaisesRegex(m.Mps4Error, "repair board.txt by hand"):
            self.restore()
        self.assertEqual(self.board(), b"")

    def test_restore_damaged_board_txt_without_kept_copy(self):
        self.set_board(b"")
        with self.assertRaisesRegex(m.Mps4Error, "repair board.txt by hand"):
            self.restore()
        self.assertEqual(self.board(), b"")

    def test_restore_appfile(self):
        self.install()
        self.restore("X\\y.txt")
        self.assertEqual(m.get_appfile(m.read_text(self.hbi / "board.txt")), "X\\y.txt")
        self.assertEqual(self.board(), BOARD_TXT.replace(b"CA5DS\\ca5ds.txt", b"X\\y.txt"))
        for bad in ("", "A B\\c.txt", "X\\y.txt;c", "caf\u00e9\\x.txt"):
            with self.subTest(appfile=bad), self.assertRaisesRegex(m.Mps4Error, "without spaces"):
                self.restore(bad)

    def test_restore_never_selects_a_file_missing_on_the_card(self):
        self.install()
        before = self.board()
        # bash without quotes drops the backslash: CA5DSca5ds.txt is no file
        for bad in ("CA5DSca5ds.txt", "NOPE\\nope.txt"):
            with self.subTest(appfile=bad), self.assertRaisesRegex(m.Mps4Error, "is not a file under"):
                self.restore(bad)
            self.assertEqual(self.board(), before)
        self.restore("ca5ds\\CA5DS.TXT")      # FAT ignores case
        self.assertEqual(m.get_appfile(m.read_text(self.hbi / "board.txt")), "ca5ds\\CA5DS.TXT")
        # the kept copy names a design the other team has removed since
        self.set_board(SELECTS_BOW32)
        (self.hbi / "CA5DS" / "ca5ds.txt").unlink()
        with self.assertRaisesRegex(m.Mps4Error, "is not a file under"):
            self.restore()
        self.assertEqual(self.board(), SELECTS_BOW32)

    def test_restore_appfile_refuses_bow32(self):
        self.install()
        self.restore()
        with self.assertRaisesRegex(m.Mps4Error, "use `install`"):
            self.restore("bow32\\BOW32.txt")
        self.assertEqual(self.board(), BOARD_TXT)

    def test_board_txt_temp_file_is_in_bow32(self):
        self.install()
        staged = []
        real = m.stage

        def spy(path, fill, tmp_dir=None):
            tmp = real(path, fill, tmp_dir)
            staged.append(tmp)
            return tmp
        with mock.patch.object(m, "stage", spy):
            self.restore()
        self.assertTrue(staged)
        self.assertTrue(all(t.parent.name == "BOW32" for t in staged), staged)
        self.assertEqual(self.leftovers(), [])

    def test_read_only_check_uses_the_mode_bits(self):
        self.install()
        board = self.hbi / "board.txt"
        board.chmod(0o444)
        try:   # as if root: os.access says yes, the mode still says read-only
            with mock.patch.object(m.os, "access", lambda *a, **k: True), \
                 self.assertRaisesRegex(m.Mps4Error, "read-only"):
                self.restore()
        finally:
            board.chmod(0o644)

    def test_appfile_value_ends_at_a_semicolon(self):
        # the MCC reads ';' as the start of a comment, also without a space before it
        glued = BOARD_TXT.replace(b"CA5DS\\ca5ds.txt      ;", b"BOW32\\bow32.txt;")
        text = glued.decode("latin-1")
        self.assertEqual(m.get_appfile(text), m.APPFILE)
        self.assertTrue(m.selects_bow32(m.get_appfile(text)))
        self.assertIn("APPFILE: X\\y.txt;Cortex", m.set_appfile(text, "X\\y.txt"))

    def test_read_only_board_txt_is_not_replaced(self):
        self.install()
        board = self.hbi / "board.txt"
        before = board.read_bytes()
        board.chmod(0o444)
        try:
            with self.assertRaisesRegex(m.Mps4Error, "read-only"):
                self.restore()
            self.assertEqual(board.read_bytes(), before)
        finally:
            board.chmod(0o644)

    def test_restore_appfile_on_damaged_board_txt(self):
        self.install()
        self.set_board(b"BOARD: HBI0376B\r\n")
        rc, out, err = self.main("restore", "--appfile", "X\\y.txt")
        self.assertEqual(rc, 1)
        self.assertIn("is damaged (no single APPFILE line): repair it by hand", err)
        self.assertEqual(self.board(), b"BOARD: HBI0376B\r\n")

    def test_install_on_a_card_that_selects_bow32(self):
        self.set_board(SELECTS_BOW32)
        self.install()
        self.assertFalse((self.hbi / "BOW32" / m.BACKUP).exists())
        self.assertFalse((self.state / m.BACKUP).exists())
        self.assertIn(f"warning: board.txt already selects {m.APPFILE} and the card has no "
                      f"{m.BACKUP}: `restore` will need --appfile", self.log)
        self.state.mkdir()
        (self.state / m.BACKUP).write_bytes(BOARD_TXT)
        self.install()
        self.assertTrue(self.logged(f"`restore` will use {self.state / m.BACKUP}"))
        self.restore()
        self.assertEqual(self.board(), BOARD_TXT)

    def test_install_appfile_in_other_case_is_bow32(self):
        self.install()
        self.set_board(self.board().replace(b"BOW32\\bow32.txt", b"bow32\\BOW32.TXT"))
        self.install()
        self.assertEqual(self.kept(), (BOARD_TXT, BOARD_TXT))
        self.assertEqual(self.board(), SELECTS_BOW32)

    def test_install_needs_a_build(self):
        with self.assertRaises(m.Mps4Error):
            m.install(self.card, self.build / "nothing", self.state, log=self.log.append)

    def test_install_refuses_a_damaged_board_txt(self):
        self.set_board(BOARD_TXT + b"APPFILE: X\\x.txt\r\n")
        with self.assertRaisesRegex(m.Mps4Error, "expected one APPFILE line, found 2"):
            self.install()
        self.assertFalse((self.hbi / "BOW32").exists())

    def test_default_state_dir_is_looked_up_at_call_time(self):
        state = Path(self.tmp.name) / "patched"
        with mock.patch.object(m, "STATE_DIR", state):
            m.install(self.card, self.build, log=self.log.append)
            self.assertEqual((state / m.BACKUP).read_bytes(), BOARD_TXT)
            (self.hbi / "BOW32" / m.BACKUP).unlink()
            m.restore(self.card, log=self.log.append)
        self.assertEqual(self.board(), BOARD_TXT)
        self.assertFalse(self.state.exists())


class WholeFileTest(Tmp):
    """Writes that fail half way leave the card booting what it booted before."""

    def test_write_text(self):
        board = self.hbi / "board.txt"
        m.write_text(board, "APPFILE: X\\x.txt\r\n")
        self.assertEqual(self.board(), b"APPFILE: X\\x.txt\r\n")
        self.assertEqual(self.leftovers(), [])
        # PATH.new cannot even be created: that error, not one from the clean-up
        with self.assertRaises(FileNotFoundError):
            m.write_text(self.card / "gone" / "board.txt", "x")

    def test_write_text_failing(self):
        board = self.hbi / "board.txt"
        for target, exc in (("fsync", OSError(errno.EIO, "I/O error")),
                            ("replace", OSError(errno.EIO, "I/O error")),
                            ("fsync", KeyboardInterrupt())):
            with self.subTest(target=target, exc=type(exc).__name__):
                with mock.patch.object(m.os, target, side_effect=exc), \
                        self.assertRaises(type(exc)):
                    m.write_text(board, "APPFILE: X\\x.txt\r\n")
                self.assertEqual(self.board(), BOARD_TXT)
                self.assertEqual(self.leftovers(), [])

    def test_restore_failing_keeps_board_txt(self):
        self.install()
        before = self.board()
        with mock.patch.object(m.os, "replace", side_effect=OSError(errno.EIO, "I/O error")), \
                self.assertRaises(OSError):
            self.restore()
        self.assertEqual(self.board(), before)
        self.assertEqual(self.leftovers(), [])

    def test_reinstall_failing_keeps_the_previous_build(self):
        self.install()
        before = self.board()
        make_build(self.build, b"BIT2" * 1000)
        for name in m.FILES:         # the bitstream, and the file staged after it
            for exc in (OSError(errno.ENOSPC, "No space left on device"), KeyboardInterrupt()):
                with self.subTest(name=name, exc=type(exc).__name__):
                    with failing_copy(name, exc), self.assertRaises(type(exc)):
                        self.install()
                    self.assertEqual(self.bit(), b"BIT1")
                    self.assertEqual(self.board(), before)
                    self.assertEqual(self.leftovers(), [])
        self.install()
        self.assertEqual(self.bit(), b"BIT2" * 1000)

    def test_read_back_differs(self):
        self.install()
        make_build(self.build, b"BIT2")
        with mock.patch.object(m.filecmp, "cmp", return_value=False), \
                self.assertRaisesRegex(m.Mps4Error, "read back differs"):
            self.install()
        self.assertEqual(self.bit(), b"BIT1")
        self.assertEqual(self.leftovers(), [])

    def test_first_install_failing_leaves_their_board_txt(self):
        with failing_copy("bow32.bit", OSError(errno.ENOSPC, "No space left on device")), \
                self.assertRaises(OSError):
            self.install()
        self.assertEqual(self.board(), BOARD_TXT)
        self.assertFalse((self.hbi / "BOW32" / "bow32.bit").exists())
        self.assertEqual(self.leftovers(), [])

    def test_main_reports_the_error_and_the_card_state(self):
        make_build(self.build, b"BIT1" * 1000)
        with failing_copy("bow32.bit", OSError(errno.ENOSPC, "No space left on device")):
            rc, out, err = self.main("install", self.build)
        self.assertEqual(rc, 1)
        self.assertIn("error: [Errno 28] No space left on device", err)
        self.assertIn("card: board.txt not changed, APPFILE CA5DS\\ca5ds.txt", err)
        self.assertNotIn("Traceback", err)
        # a re-install: the card keeps the previous Bow32 build
        self.assertEqual(self.main("install", self.build)[0], 0)
        make_build(self.build, b"BIT2" * 1000)
        with failing_copy("bow32.txt", KeyboardInterrupt()):
            rc, out, err = self.main("install", self.build)
        self.assertEqual(rc, 1)
        self.assertIn("error: interrupted", err)
        self.assertIn(f"card: board.txt not changed, APPFILE {m.APPFILE} (BOW32 files:", err)
        self.assertEqual(self.bit(), b"BIT1" * 1000)


class MountTest(Tmp):
    def test_mount_and_umount(self):
        with FakeMount() as fm:
            with m.Card(self.card, log=self.log.append) as root:
                self.assertEqual(root, self.card)
        self.assertEqual(fm.cmds, ["mount", "umount"])
        self.assertFalse(fm.mounted)

    def test_foreign_drive_is_unmounted_again(self):
        shutil.rmtree(self.hbi)
        with FakeMount() as fm, self.assertRaisesRegex(m.Mps4Error, "not the MPS4 card"):
            with m.Card(self.card, log=self.log.append):
                self.fail("the block must not run")
        self.assertEqual(fm.cmds, ["mount", "umount"])
        self.assertFalse(fm.mounted)

    def test_drive_mounted_by_the_user_is_left_alone(self):
        shutil.rmtree(self.hbi)
        with FakeMount(mounted=True) as fm, self.assertRaises(m.Mps4Error):
            with m.Card(self.card, log=self.log.append):
                pass
        self.assertEqual(fm.cmds, [])

    def test_busy_umount_keeps_the_real_error(self):
        card = m.Card(self.card, log=self.log.append)
        with FakeMount(busy=True), self.assertRaisesRegex(m.Mps4Error, "read back differs"):
            with card:
                raise m.Mps4Error("read back differs")
        self.assertTrue(any(s.startswith("warning: umount") and "still mounted" in s for s in self.log))
        self.assertEqual(card.state, "card: board.txt not changed, APPFILE CA5DS\\ca5ds.txt")
        # foreign drive and busy umount: the check's error, not the umount's
        shutil.rmtree(self.hbi)
        with FakeMount(busy=True), self.assertRaisesRegex(m.Mps4Error, "not the MPS4 card"):
            with m.Card(self.card, log=self.log.append):
                pass

    def test_busy_umount_after_success_is_the_error(self):
        with FakeMount(busy=True), self.assertRaisesRegex(m.Mps4Error, "target is busy"):
            with m.Card(self.card, log=self.log.append):
                pass

    def test_run_reports_the_command_and_its_message(self):
        REAL_RUN(["true"])
        with self.assertRaisesRegex(m.Mps4Error, r"^sh -c .*: umount: /mnt/x: target is busy\.$"):
            REAL_RUN(["sh", "-c", "echo 'umount: /mnt/x: target is busy.' >&2; exit 32"])

    def test_state_after_a_failure(self):
        card = m.Card(self.card, log=self.log.append)
        with FakeMount(mounted=True), self.assertRaises(KeyboardInterrupt):
            with card as root:
                m.write_text(root / m.HBI / "board.txt", SELECTS_BOW32.decode("latin-1"))
                raise KeyboardInterrupt
        self.assertTrue(card.state.startswith(f"card: board.txt changed, APPFILE {m.APPFILE}"))
        card = m.Card(self.card, log=self.log.append)
        with FakeMount(mounted=True), self.assertRaises(OSError):
            with card as root:
                (root / m.HBI / "board.txt").unlink()
                raise OSError(errno.EIO, "I/O error")
        self.assertIn("cannot be read back", card.state)

    def test_main_busy_umount_keeps_the_install_error(self):
        with FakeMount(mounted=True, busy=True), \
                mock.patch.object(m.filecmp, "cmp", return_value=False):
            rc, out, err = self.main("install", self.build, mount=True)
        self.assertEqual(rc, 1)
        self.assertIn("read back differs", err)
        self.assertIn("card: board.txt not changed, APPFILE CA5DS\\ca5ds.txt", err)
        self.assertIn("target is busy", out)
        self.assertEqual(self.board(), BOARD_TXT)

    def test_main_no_mount(self):
        self.assertEqual(self.main("install", self.build)[0], 0)
        # main() passes no state_dir: the host copy is in the patched STATE_DIR
        self.assertEqual(self.kept(), (BOARD_TXT, BOARD_TXT))
        rc, out, err = self.main("show")
        self.assertEqual(rc, 0)
        self.assertIn(f"APPFILE: {m.APPFILE}", out)
        self.assertEqual(self.main("restore")[0], 0)
        rc, out, err = self.main("restore")
        self.assertEqual(rc, 0)
        self.assertIn("nothing to restore", out)
        self.assertEqual(self.board(), BOARD_TXT)
        rc, out, err = self.main("show", mnt=self.card / "x")
        self.assertEqual(rc, 1)
        self.assertIn("not the MPS4 card", err)


class FakeBoard:
    """MCC console (port 'mcc') and Bow32 UART0 (port 'con') of an MPS4."""

    def __init__(self, boots=True, configures=True):
        self.out = {"mcc": bytearray(b"\r\nCmd> "), "con": bytearray()}
        self.boots, self.configures, self.written = boots, configures, []

    def opener(self, name):
        return FakePort(self, name)


class FakePort:
    def __init__(self, board, name):
        self.board, self.name = board, name

    def write(self, data):
        self.board.written.append((self.name, data))
        if self.name != "mcc":
            return
        out = self.board.out
        if b"REBOOT" in data:
            out["mcc"] += b"REBOOT\r\nRebooting...\r\n"
            if self.board.boots:
                # the real progress format: CR separated entries on one line
                out["mcc"] += (b"Configuring FPGA from file \\MB\\HBI0376B\\BOW32\\bow32.bit\r\n"
                               b"\rAddress: 0x00000000\rAddress: 0x00040000\rAddress: 0x00080000\r\n"
                               + (b"FPGA configuration complete.\r\n" if self.board.configures else
                                  b"ERROR: FPGA configuration failed\r\n") +
                               b"UART0: MCC, UART1: FPGA0\r\nReleasing CB_nRST\r\nCmd> ")
                out["con"] += BANNER
        elif b"RESET" in data:
            out["mcc"] += b"RESET\r\n\r\nExternal reset request...\r\nResets released...\r\nCmd> "
            out["con"] += BANNER

    def read(self, n):
        buf = self.board.out[self.name]
        data = bytes(buf[:n])
        del buf[:n]
        return data

    def close(self):
        pass


@mock.patch("bow32_mps4.time.sleep")
class MccTest(unittest.TestCase):
    def test_reboot(self, _sleep):
        board, log = FakeBoard(), []
        out = m.mcc_reboot("mcc", "con", board.opener, settle_s=0.05, log=log.append)
        self.assertIn("Bow32 boot ROM", out)
        self.assertIn(("mcc", b"REBOOT\r"), board.written)
        self.assertIn("MCC: Releasing CB_nRST", log)
        self.assertIn("MCC: (3 x 256 KiB programmed)", log)
        self.assertIn("MCC: FPGA configuration complete.", log)
        self.assertFalse(any("Address" in line or "ress:" in line for line in log))

    def test_reboot_without_configuration_is_an_error(self, _sleep):
        board = FakeBoard(configures=False)
        with self.assertRaisesRegex(m.Mps4Error, "FPGA configuration complete"):
            m.mcc_reboot("mcc", "con", board.opener, settle_s=0.05, log=lambda s: None)

    def test_reboot_timeout(self, _sleep):
        with self.assertRaises(m.Mps4Error):
            m.mcc_reboot("mcc", "con", FakeBoard(boots=False).opener, timeout_s=0.2, settle_s=0.05,
                         log=lambda s: None)

    def test_reset(self, _sleep):
        board = FakeBoard()
        out = m.mcc_reset("mcc", "con", board.opener, settle_s=0.05, log=lambda s: None)
        self.assertIn("ddr: Bow32 DDR2 x8", out)
        self.assertIn(("mcc", b"RESET\r"), board.written)

    def test_find_port(self, _sleep):
        self.assertEqual(m.find_port(0, "/dev/x"), "/dev/x")
        with mock.patch("bow32_mps4.glob.glob", return_value=["/a", "/b"]):
            with self.assertRaises(m.Mps4Error):
                m.find_port(1)


@mock.patch("bow32_mps4.time.sleep")
class MainMccTest(Tmp):
    def test_deploy(self, _sleep):
        rc, out, err = self.main("--mcc", "mcc", "--console", "con", "--settle", "0.05",
                                 "deploy", self.build, opener=FakeBoard().opener)
        self.assertEqual((rc, err), (0, ""))
        self.assertIn("--- Bow32 console (con)", out)
        self.assertIn("Bow32 boot ROM", out)
        self.assertEqual(self.bit(), b"BIT1")

    def test_ctrl_c_while_watching(self, _sleep):
        def opener(name):
            raise KeyboardInterrupt
        rc, out, err = self.main("--mcc", "mcc", "--console", "con", "reboot", opener=opener)
        self.assertEqual((rc, err), (1, "error: interrupted\n"))


if __name__ == "__main__":
    unittest.main()
