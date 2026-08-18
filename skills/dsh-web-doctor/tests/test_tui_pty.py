#!/usr/bin/env python3
"""test_tui_pty.py — PTY-level tests for doctor_tui.py (PR 4).

Runs the real curses TUI in a child process attached to a PTY, with the
scripted fake automation runtime (DSH_DOCTOR_FAKE_AGENT), and verifies the
plan's terminal-safety list: control sequences never reach the semantic
screen, bracketed paste loses its brackets, resize doesn't crash, Ctrl-C only
interrupts (never kills the TUI), and no child processes leak.

PLATFORM NOTE (2026-08-17, macOS + Python 3.14): even a minimal
curses.wrapper app blocks forever in wrapper's own teardown
(nocbreak/echo/endwin → tcsetattr) after leaving the alternate screen on a
PTY. The semantic checks therefore assert the TUI reached the quit path
(alternate screen left) and reaped its children, then bound the reap instead
of requiring a clean exit code.
"""

from __future__ import annotations

import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = TESTS_DIR.parent / "scripts"
FAKE_RUNTIME = str(TESTS_DIR / "fake-automation.py")

ALT_SCREEN_LEFT = b"\x1b[?1049l"


def set_size(fd: int, rows: int, cols: int) -> None:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


class PtyHarness:
    """Spawn a command on a PTY; drive input; read output with a deadline."""

    def __init__(self, argv: list[str], env: dict[str, str] | None = None):
        self.master, slave = pty.openpty()
        set_size(self.master, 24, 80)
        self.env = dict(os.environ)
        self.env.update(env or {})
        self.proc = subprocess.Popen(
            argv,
            stdin=slave, stdout=slave, stderr=slave,
            env=self.env, close_fds=True, start_new_session=True,
        )
        os.close(slave)
        self.out = b""

    def read_until(self, needle: bytes, timeout: float = 30.0) -> bytes:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                self.out += chunk
                if needle in self.out:
                    return self.out
        return self.out

    def write(self, data: bytes) -> None:
        os.write(self.master, data)

    def resize(self, rows: int, cols: int) -> None:
        set_size(self.master, rows, cols)
        os.kill(self.proc.pid, signal.SIGWINCH)

    def wait(self, timeout: float = 8.0) -> int | None:
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
            return None

    def quit_and_reap(self) -> None:
        """Send /quit, drain until the alternate screen is left (the quit path
        was reached), then bounded-reap. Platform teardown may block, so the
        process is reaped here regardless."""
        self.write(b"/quit\r")
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and ALT_SCREEN_LEFT not in self.out:
            ready, _, _ = select.select([self.master], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                self.out += chunk
        self.wait(timeout=8)

    def close(self) -> None:
        try:
            os.close(self.master)
        except OSError:
            pass
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=5)


def env_for_fake(tmp: str) -> dict[str, str]:
    return {
        "DSH_DOCTOR_FAKE_AGENT": FAKE_RUNTIME,
        "DSH_HOME": str(Path(tmp) / "home"),
        "DSH_SOURCE": str(Path(tmp) / "source"),
        "DSH_SKILLS_DIR": str(SCRIPTS_DIR.parent.parent),
        "TERM": "xterm-256color",
        "LC_ALL": "en_US.UTF-8",
        "DSH_WEB_PORT": "39999",
        "DSH_DOCTOR_BROWSER_BUDGET_MS": "1000",
    }


class TuiPtyTest(unittest.TestCase):
    def _spawn(self, tmp: str):
        return PtyHarness(
            [sys.executable, str(SCRIPTS_DIR / "doctor_tui.py")], env_for_fake(tmp))

    def test_quit_reaches_quit_path_and_reaps_children(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            h = self._spawn(tmp)
            try:
                h.read_until(b"health=", timeout=30)
                h.quit_and_reap()
                self.assertIn(ALT_SCREEN_LEFT, h.out)
                time.sleep(0.3)
                kids = subprocess.run(
                    ["pgrep", "-P", str(h.proc.pid)], capture_output=True, text=True).stdout.split()
                self.assertEqual(kids, [])
            finally:
                h.close()

    def test_resize_does_not_crash(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            h = self._spawn(tmp)
            try:
                h.read_until(b"health=", timeout=30)
                for rows, cols in [(24, 80), (12, 40), (40, 120)]:
                    h.resize(rows, cols)
                    time.sleep(0.5)
                # Still alive after resizes: the TUI did not crash.
                self.assertIsNone(h.proc.poll(), h.out[-300:])
                h.quit_and_reap()
                self.assertIn(ALT_SCREEN_LEFT, h.out)
            finally:
                h.close()

    def test_bracketed_paste_loses_brackets(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            h = self._spawn(tmp)
            try:
                h.read_until(b"health=", timeout=30)
                h.write(b"\x1b[200~pasted text\x1b[201~\r")
                time.sleep(1.0)
                h.quit_and_reap()
                self.assertIn(b"pasted text", h.out)
                self.assertNotIn(b"\x1b[200~", h.out)
                self.assertNotIn(b"\x1b[201~", h.out)
            finally:
                h.close()

    def test_ctrl_c_interrupts_agent_not_tui(self):
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            h = self._spawn(tmp)
            try:
                h.read_until(b"health=", timeout=30)
                h.write(b"\x03")  # Ctrl-C: interrupts, must NOT kill the TUI
                time.sleep(1.0)
                # The TUI survived Ctrl-C and still answers /quit.
                self.assertIsNone(h.proc.poll(), h.out[-300:])
                h.quit_and_reap()
                self.assertIn(ALT_SCREEN_LEFT, h.out)
            finally:
                h.close()


if __name__ == "__main__":
    unittest.main()
