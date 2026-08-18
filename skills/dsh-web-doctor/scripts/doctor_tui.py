#!/usr/bin/env python3
"""
doctor_tui.py — event-driven curses surface for dsh-web-doctor (PR 4).

The curses thread ONLY draws and reads keys; every external activity happens
off-thread and arrives as events:
  - the persistent automation agent (doctor_agent.PersistentAgentClient) has
    its own reader thread; its notifications (session.event / session.status)
    are pumped into a SimpleQueue the render loop drains
  - DoctorController (doctor_controller) owns health/agent state and the
    user-message priority; the TUI renders its events

There is no session-log tailing, no zstd re-decompression, no "global latest
session" guessing, no blocking curl/subprocess in the draw path.

Terminal safety:
  - every model/agent/log string passes sanitize_terminal_text() before
    rendering (strips CSI/OSC/DCS/APC/PM, non-\n\t C0/C1, invalid Unicode)
  - bracketed paste (ESC[200~ … ESC[201~) is captured and inserted verbatim
    without the bracketing sequences
  - unknown control sequences are dropped, never echoed
  - termios is saved on entry and exactly restored in a finally
  - Ctrl-C generates an interrupt event; it cancels the agent turn, never
    the TUI process
"""

from __future__ import annotations

import argparse
import curses
import enum
import locale
import os
import queue
import re
import sys
import termios
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import doctor_agent as agent  # noqa: E402
import doctor_controller as controller  # noqa: E402
import doctor_core as core  # noqa: E402

# ---------------------------------------------------------------------------
# terminal sanitization
# ---------------------------------------------------------------------------

# CSI: ESC [ ... final (0x40–0x7E); OSC: ESC ] ... BEL/ST; DCS/APC/PM:
# ESC P / ESC _ / ESC ^ ... ST. Strip the whole run, keep the ESC of the
# next real character intact (matched non-greedily).
_CTRL_SEQUENCE = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"       # CSI
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC … BEL/ST
    r"|\x1b[P_^][^\x1b]*(?:\x1b\\)?"      # DCS/APM/PM … ST
    r"|\x1b[@-Z\\-_]"                 # lone 2-char escapes
)
_C0_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")  # keep \n \t
_INVALID_UNICODE = re.compile(r"[\ud800-\udfff]")

# Input: ESC followed by a CSI sequence (arrows, F-keys, tilde keys) or a
# single char (Alt+key). Bracketed paste is handled explicitly.
_CURSOR_KEYS = {
    "KEY_UP": ("\x1b[A", "KEY_UP"),
    "KEY_DOWN": ("\x1b[B", "KEY_DOWN"),
    "KEY_RIGHT": ("\x1b[C", "KEY_RIGHT"),
    "KEY_LEFT": ("\x1b[D", "KEY_LEFT"),
    "KEY_HOME": ("\x1b[H", "KEY_HOME"),
    "KEY_END": ("\x1b[F", "KEY_END"),
    "KEY_BACKSPACE": ("\x7f", "KEY_BACKSPACE"),
    "KEY_DC": ("\x1b[3~", "KEY_DC"),
    "KEY_PPAGE": ("\x1b[5~", "KEY_PPAGE"),
    "KEY_NPAGE": ("\x1b[6~", "KEY_NPAGE"),
}


def sanitize_terminal_text(text: str) -> str:
    """Strip every terminal control sequence and unprintable byte from a
    string bound for the renderer. Keeps \\n and \\t."""
    if not text:
        return text
    cleaned = _CTRL_SEQUENCE.sub("", text)
    cleaned = _C0_CONTROL.sub("", cleaned)
    return _INVALID_UNICODE.sub("\ufffd", cleaned)


class Renderer:
    """Terminal-independent transcript model: bounded lines, logical wrap.
    The curses adapter below paints it; tests use it without a terminal."""

    def __init__(self, max_lines: int = 2000, width: int = 80):
        self.max_lines = max_lines
        self.width = width
        self.lines: list[str] = []

    def add(self, text: str) -> None:
        text = sanitize_terminal_text(text)
        for raw in text.split("\n"):
            if raw == "":
                self.lines.append("")
                continue
            while len(raw) > self.width:
                self.lines.append(raw[:self.width])
                raw = raw[self.width:]
            self.lines.append(raw)
        if len(self.lines) > self.max_lines:
            del self.lines[: len(self.lines) - self.max_lines]

    def clear(self) -> None:
        self.lines = []

    def render(self, height: int, start: int = 0) -> list[str]:
        """The last `height` lines starting from `start` lines back."""
        end = len(self.lines) - start
        begin = max(0, end - height)
        return self.lines[begin:end]


# ---------------------------------------------------------------------------
# curses surface
# ---------------------------------------------------------------------------


class DoctorTui:
    """Curses adapter over Renderer + DoctorController + PersistentAgentClient."""

    def __init__(self, scr, ctx: core.RunContext, *, verbose: bool = False) -> None:
        self.scr = scr
        self.ctx = ctx
        self.verbose = verbose
        self.renderer = Renderer()
        self.events: queue.SimpleQueue = queue.SimpleQueue()
        self.input_buffer = ""
        self.paste_buffer: list[str] = []
        self.running = True
        # Test seam: DSH_DOCTOR_FAKE_AGENT=<script> runs a scripted JSON-RPC
        # runtime instead of the automation profile (PTY tests use it).
        fake = os.environ.get("DSH_DOCTOR_FAKE_AGENT")
        if fake:
            self.controller = controller.DoctorController(
                ctx,
                agent_factory=lambda: agent.PersistentAgentClient(
                    ctx, session_id="doctor", cwd=ctx.cwd,
                    dsh=sys.executable, argv=[sys.executable, fake], env=dict(os.environ),
                ),
            )
        else:
            self.controller = controller.DoctorController(ctx)
        self.controller.subscribe(self._on_controller_event)
        self._agent_client = None
        self._agent_subscription: queue.Queue | None = None
        self._worker: threading.Thread | None = None
        self._saved_termios = None

    # -- controller/agent wiring ---------------------------------------------

    def _on_controller_event(self, event: controller.ControllerEvent) -> None:
        # Called from the worker/controller context; hand to the draw loop.
        self.events.put(("controller", event))

    def start(self) -> None:
        try:
            self._saved_termios = termios.tcgetattr(sys.stdin.fileno())
        except (termios.error, OSError, ValueError):
            self._saved_termios = None
        self._worker = threading.Thread(target=self._worker_loop, daemon=True, name="doctor-tui-worker")
        self._worker.start()

    def _worker_loop(self) -> None:
        try:
            # The agent is created lazily by the controller (first prompt or
            # the initial autonomous round) — wait for it instead of racing
            # the controller's own single-flight creation.
            while self._agent_client is None and self.running:
                self._agent_client = self.controller._agent
                if self._agent_client is None:
                    time.sleep(0.1)
            if self._agent_client is not None:
                self._agent_subscription = self._agent_client.subscribe()
            # The initial autonomous round (diagnosis, safe fixes, agent
            # delegation) runs HERE — the worker — never in the draw thread
            # (it contains multi-second detectors).
            self.controller.diagnose()
            self.controller.autonomous_round()
        except Exception as error:  # noqa: BLE001
            self.events.put(("controller", controller.ControllerEvent("agent", {"state": "FAILED", "detail": str(error)})))
            return
        while self.running:
            try:
                item = self._agent_subscription.get(timeout=0.25) if self._agent_subscription else None
            except queue.Empty:
                continue
            if item is None:
                continue
            if isinstance(item, Exception):
                self.events.put(("controller", controller.ControllerEvent("agent", {"state": "FAILED", "detail": str(item)})))
                continue
            self.events.put(("notification", item))
            if item.method == "session.status" and item.params.get("status") == "idle":
                self.events.put(("task", self.controller.on_agent_idle))

    # -- input ----------------------------------------------------------------

    def handle_input(self, key: str) -> None:
        if key == "KEY_RESIZE":
            self._layout()
            return
        if key == "KEY_CTRL_C" or key == "\x03":
            # Interrupt: cancel the agent turn, never the TUI.
            if self.controller.agent_state in (controller.AgentState.RUNNING,):
                self.events.put(("task", lambda: self._interrupt_agent()))
            elif self.controller.mode is controller.ControlMode.AUTONOMOUS:
                self.events.put(("task", self.controller.request_quit))
            return
        if key == "KEY_QUIT":
            self.events.put(("task", lambda: self.controller.request_quit("user")))
            return
        if key in ("KEY_ENTER", "\n", "\r"):
            text = "".join(self.paste_buffer) + self.input_buffer
            self.input_buffer = ""
            self.paste_buffer = []
            if text.strip() == "/quit":
                self.events.put(("task", lambda: self.controller.request_quit("user")))
            elif text.strip() == "/verbose":
                self.verbose = not self.verbose
                self.renderer.add("[verbose] " + ("on" if self.verbose else "off"))
            elif text.strip():
                self.renderer.add(f"you: {text}")
                self.events.put(("task", lambda t=text: self.controller.submit_user_message(t)))
            return
        if key == "KEY_BACKSPACE" or key == "\x7f":
            self.input_buffer = self.input_buffer[:-1]
            return
        # Bracketed paste: 200~ begins a paste, 201~ ends it.
        if key == "\x1b[200~":
            self._paste_mode = True
            return
        if key == "\x1b[201~":
            self._paste_mode = False
            if self.paste_buffer:
                text = "".join(self.paste_buffer)
                self.paste_buffer = []
                self.input_buffer += text
            return
        if getattr(self, "_paste_mode", False):
            self.paste_buffer.append(key)
            return
        if key.startswith("\x1b["):
            # Unknown CSI sequence: drop it, never echo into the input line.
            return
        if len(key) == 1 and key.isprintable() or key == " ":
            self.input_buffer += key

    def _interrupt_agent(self) -> None:
        try:
            self.controller._agent.cancel()
        except Exception:  # noqa: BLE001
            pass
        self.controller.on_agent_idle()

    # -- drawing --------------------------------------------------------------

    def _layout(self) -> None:
        self.scr.erase()
        height, width = self.scr.getmaxyx()
        self.renderer.width = max(10, width - 2)
        status = (
            f" health={self.controller.health.value}"
            f" agent={self.controller.agent_state.value}"
            f" mode={self.controller.mode.value}"
            f"  (Ctrl-C=interrupt  /quit=exit  /verbose={self.verbose})"
        )
        try:
            self.scr.addnstr(0, 0, sanitize_terminal_text(status)[: width - 1], width - 1)
            self.scr.hline(1, 0, "-", width - 1)
        except curses.error:
            pass
        lines = self.renderer.render(height - 3)
        for index, line in enumerate(lines):
            try:
                self.scr.addnstr(index + 2, 0, line[: width - 1], width - 1)
            except curses.error:
                break
        prompt = "> " + self.input_buffer
        try:
            self.scr.addnstr(height - 1, 0, sanitize_terminal_text(prompt)[: width - 1], width - 1)
        except curses.error:
            pass
        self.scr.noutrefresh()

    def draw(self) -> None:
        self._layout()
        curses.doupdate()

    def run(self) -> int:
        curses.cbreak()
        curses.noecho()
        self.scr.keypad(True)
        self.scr.timeout(100)
        self.start()
        self._paste_mode = False
        try:
            while self.running:
                self._drain_events()
                self.draw()
                self.running = not self.controller.quit
                if not self.running:
                    break
                try:
                    key = self.scr.get_wch()
                except curses.error:
                    continue
                self.handle_input(key)
                # Re-drain so a queued quit lands promptly.
                self._drain_events()
                self.running = not self.controller.quit
        finally:
            self._restore_terminal()
        self.renderer.add("doctor closed.")
        return 0

    def _drain_events(self) -> None:
        while True:
            try:
                item = self.events.get_nowait()
            except queue.Empty:
                return
            kind = item[0]
            if kind == "controller":
                event = item[1]
                if event.kind == "agent":
                    state = event.detail.get("state") if isinstance(event.detail, dict) else None
                    if state == "FAILED" and event.detail:
                        self.renderer.add(f"[agent] failed: {event.detail.get('detail', '')}")
                elif event.kind == "health":
                    self.renderer.add(f"[health] {event.detail}")
                elif event.kind == "repair":
                    self.renderer.add(f"[repair] {event.detail}")
                elif event.kind == "message":
                    self.renderer.add(f"[sent] gen={event.detail.get('generation')}")
                elif event.kind == "quit":
                    self.renderer.add("doctor closed.")
            elif kind == "notification":
                self._render_notification(item[1])
            elif kind == "task":
                try:
                    item[1]()
                except Exception as error:  # noqa: BLE001
                    self.renderer.add(f"[error] {error}")

    def _render_notification(self, notification: agent.Notification) -> None:
        if notification.method == "session.status":
            status = notification.params.get("status")
            self.renderer.add(f"[agent] {status}")
            return
        if notification.method != "session.event":
            return
        event = notification.params.get("event")
        if not isinstance(event, dict):
            return
        event_type = event.get("type")
        if event_type == "assistant/message":
            message = event.get("data", {}).get("message", {}) if isinstance(event.get("data"), dict) else {}
            for block in message.get("content", []) if isinstance(message, dict) else []:
                if isinstance(block, dict) and block.get("type") == "text":
                    self.renderer.add(str(block.get("text", "")))
        elif event_type == "tool/call" and self.verbose:
            data = event.get("data", {}) if isinstance(event.get("data"), dict) else {}
            self.renderer.add(f"[tool] {data.get('name', '?')}")
        elif event_type == "turn/end":
            data = event.get("data", {}) if isinstance(event.get("data"), dict) else {}
            reason = data.get("reason", {})
            self.renderer.add(f"[turn end] {reason.get('kind', '?') if isinstance(reason, dict) else reason}")

    def _restore_terminal(self) -> None:
        # Terminal restoration is entirely owned by curses.wrapper's
        # initscr/endwin finally (which restores the exact termios). Any
        # additional curses mode call here (tcsetattr under the hood) blocks
        # on some PTY setups after endwin, so this surface adds nothing.
        pass


# ---------------------------------------------------------------------------
# entry
# ---------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="doctor-tui")
    parser.add_argument("--verbose", action="store_true", help="show tool/reasoning detail")
    parser.add_argument("--selftest", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def selftest() -> int:
    """Sanitizer + renderer smoke test without a terminal."""
    samples = [
        "\x1b[31mred\x1b[0m",
        "\x1b]0;title\x07text",
        "\x1b[200~pasted\x1b[201~",
        "\x1b[Aup",
        "plain **bold** \x00\x0b\x08 ok",
        "中文宽字符测试",
    ]
    for sample in samples:
        cleaned = sanitize_terminal_text(sample)
        assert "\x1b" not in cleaned, repr(cleaned)
        assert "\x00" not in cleaned and "\x0b" not in cleaned, repr(cleaned)
    r = Renderer(width=10)
    r.add("0123456789abcdefghij")
    assert r.lines[-1] == "abcdefghij", r.lines
    print("SELFTEST OK")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if args.selftest:
        return selftest()
    # UTF-8 locale first: without it curses reads CJK byte-wise and wide
    # characters overflow chtype (2026-08-17).
    try:
        locale.setlocale(locale.LC_ALL, "")
    except locale.Error:
        pass
    ctx = core.RunContext(quiet=True)

    def run(scr) -> int:
        tui = DoctorTui(scr, ctx, verbose=args.verbose)
        return tui.run()

    return curses.wrapper(run)


if __name__ == "__main__":
    sys.exit(main())
