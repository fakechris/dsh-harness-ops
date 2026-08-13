#!/usr/bin/env python3
"""
doctor-tui.py — the REAL mini TUI for dsh-web-doctor.

A full-screen interactive terminal UI (curses, stdlib only — python3 is an
accepted doctor dependency, it is already used by doctor.sh):

  - top status bar: web status / current slot / phase / agent state / keys
  - scrollable main pane: deterministic diagnosis + per-problem fixes +
    the LLM session, with PROMPT and CoT rendered as MARKDOWN
    (headings / bold / italic / inline code / fenced code blocks / lists /
    blockquotes), not raw text
  - bottom input bar: you can TYPE at any time —
      * during fixes:  y / n / ? / q
      * during the LLM phase: a message to the agent (Enter = run),
        Ctrl-C = interrupt the running agent, then type guidance and Enter
        to continue the same conversation (context is carried forward)

Why this exists (2026-08-13): an unattended `--agent` run once burned its
whole timeout fixing nothing. Long doctor tasks without a human steering them
are unreliable. This TUI is the human-in-the-loop doctor: every fix confirmed,
the LLM steered by you, nothing runs unattended unless you send it.

Out-of-band & minimal-dependency: python3 stdlib + the same system tools the
rest of the doctor uses (zstd/curl/node). No pip packages.
"""

import curses
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import deque

HOME = os.path.expanduser("~")
SKILLS_DIR = os.environ.get("DSH_SKILLS_DIR", os.path.join(HOME, ".dsh", "skills"))
DSH_SOURCE = os.environ.get("DSH_SOURCE", os.path.join(HOME, ".dsh", "source"))
PORT = os.environ.get("DSH_WEB_PORT", "3080")
DOCTOR = os.path.join(SKILLS_DIR, "dsh-web-doctor", "scripts", "doctor.sh")
CHAT_CTX = os.environ.get("DSH_DOCTOR_CHAT_CTX", "/tmp/dsh-doctor-chat.txt")
AGENT_TIMEOUT = int(os.environ.get("DSH_DOCTOR_AGENT_TIMEOUT", "300"))

WEB_URL = "http://127.0.0.1:%s/" % PORT


# ---------------------------------------------------------------------------
# tiny helpers
# ---------------------------------------------------------------------------
def strip_ansi(s):
    return re.sub(r"\x1b\[[0-9;]*m", "", s)


def run_capture(args, **kw):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=kw.pop("timeout", 120),
                           stdin=subprocess.DEVNULL, **kw)
        return p.returncode, strip_ansi(p.stdout) + strip_ansi(p.stderr)
    except subprocess.TimeoutExpired:
        return 124, "(timed out)"
    except Exception as e:
        return 127, "(cannot run: %s)" % e


def web_code():
    try:
        p = subprocess.run(
            ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", WEB_URL],
            capture_output=True, text=True,
        )
        return (p.stdout or "").strip() or "000"
    except Exception:
        return "000"


def dsh_path():
    p = os.path.join(HOME, ".local", "bin", "dsh")
    if os.path.exists(p):
        return p
    return shutil.which("dsh") or "dsh"


def session_logs():
    return set(glob_join(HOME, ".dsh", "sessions", "*", "*", "session.jsonl.zstd"))


def glob_join(*parts):
    import glob
    return glob.glob(os.path.join(*parts))


# ---------------------------------------------------------------------------
# streaming markdown renderer (line-oriented, safe on partial input)
# emits (text, style) spans; styles are mapped to curses attrs by the UI
# ---------------------------------------------------------------------------
STYLES = {
    "plain": 0, "heading": 1, "code": 2, "dim": 3, "ok": 4, "err": 5,
    "warn": 6, "user": 7, "llm": 8, "tool": 9, "fence": 10, "quote": 11,
}


class Md:
    def __init__(self):
        self.in_fence = False
        self.fence_lang = ""

    def feed(self, raw):
        """One complete line → list[(text, style)]."""
        line = raw.rstrip("\r\n")
        if self.in_fence:
            if line.strip().startswith("```") or line.strip().startswith("~~~"):
                self.in_fence = False
                return [("```", "fence")]
            return [(line, "code")]
        s = line.strip()
        if s.startswith("```") or s.startswith("~~~"):
            self.in_fence = True
            self.fence_lang = s[3:].strip()
            return [("``` %s" % self.fence_lang, "fence")]
        if not s:
            return [("", "plain")]
        if s.startswith("|") and s.endswith("|") and "|" in s[1:-1]:
            # naive table row → keep as plain, highlight separator
            if re.match(r"^\|[\s:|-]+\|$", s):
                return [(line, "dim")]
            return [(line, "plain")]
        m = re.match(r"^(#{1,6})\s+(.*)$", line)
        if m:
            return [("#" * len(m.group(1)) + " " + m.group(2), "heading")]
        m = re.match(r"^(\s*)([-*+])\s+(.*)$", line)
        if m and re.match(r"^[-*+]$", m.group(2)):
            return [(m.group(1) + "• " + m.group(3), "plain")]
        m = re.match(r"^(\s*)(\d+)[.)]\s+(.*)$", line)
        if m:
            return [(m.group(1) + m.group(2) + ". " + m.group(3), "plain")]
        m = re.match(r"^>\s?(.*)$", line)
        if m:
            return [("▍ " + m.group(1), "quote")]
        if re.match(r"^-{3,}\s*$", s):
            return [("─" * 40, "dim")]
        return self._inline(line)

    def _inline(self, line):
        out = []
        parts = re.split(r"(\*\*[^*]+\*\*|\*[^*\s][^*]*\*|`[^`]+`)", line)
        for p in parts:
            if not p:
                continue
            if p.startswith("**") and p.endswith("**") and len(p) > 4:
                out.append((p[2:-2], "heading"))
            elif p.startswith("`") and p.endswith("`") and len(p) > 2:
                out.append((p[1:-1], "code"))
            elif p.startswith("*") and p.endswith("*") and len(p) > 2:
                out.append((p[1:-1], "llm"))
            else:
                out.append((p, "plain"))
        return out


# ---------------------------------------------------------------------------
# the TUI
# ---------------------------------------------------------------------------
class Tui:
    def __init__(self, scr):
        self.scr = scr
        curses.start_color()
        curses.use_default_colors()
        self.colors = {}
        for name, idx in STYLES.items():
            fg = {
                "plain": -1, "heading": -1, "code": 6, "dim": -1, "ok": 2,
                "err": 1, "warn": 3, "user": 5, "llm": 4, "tool": 3,
                "fence": 8, "quote": 8,
            }.get(name, -1)
            if fg >= 0:
                curses.init_pair(idx + 1, fg, -1)
                self.colors[name] = curses.color_pair(idx + 1)
            else:
                self.colors[name] = 0
        self.md = Md()
        self.lines = []          # list of list[(text, attr)]
        self.scroll = 0
        self.follow = True   # auto-follow bottom; manual scroll disables
        self.input = ""
        self.msg = ""
        self.phase = "diag"      # diag | fix | llm | restart | done
        self.problems = []
        self.web = "000"
        self.last_web = 0
        self.agent = None        # subprocess
        self.agent_state = "idle"  # idle|running|interrupted|done
        self.agent_start = 0
        self.sessions_before = set()
        self.log_pos = {}        # session file -> lines consumed
        self.recent_texts = deque(maxlen=8)
        self.ctx = []            # context turns (rendered in pane already)
        self.fix_idx = 0
        self.fixed = self.skipped = self.failed = 0
        self.quit = False
        self.keyhelp_shown = False

    # ---- pane -------------------------------------------------------------
    def add(self, text, style="plain"):
        if isinstance(text, str):
            self.lines.append([(text, self.colors.get(style, 0))])
        else:
            self.lines.append(text)  # already-styled spans

    def add_md(self, raw):
        for ln in raw.splitlines() or [""]:
            spans = self.md.feed(ln)
            self.lines.append([(t, self.colors.get(s, 0)) for t, s in spans])

    def add_agent_event(self, kind, text):
        """Streamed agent event → styled pane line(s), markdown for prose."""
        if not text.strip():
            return
        if kind == "reasoning":
            for ln in text.splitlines():
                self.add_md(ln)
        elif kind == "tool":
            for ln in text.splitlines():
                self.add("[tool] " + ln.strip(), "tool")
        elif kind == "message":
            for ln in text.splitlines():
                self.add_md(ln)

    def clear_pane(self):
        self.lines = []
        self.scroll = 0
        self.follow = True

    # ---- agent -------------------------------------------------------------
    def start_agent(self, task):
        self.sessions_before = session_logs()
        self.log_pos = {}
        env = os.environ.copy()
        env["DSH_PERMISSION_MODE"] = "danger-full-access"
        self.agent = subprocess.Popen(
            [dsh_path(), "--profile", "headless", task],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            env=env,
        )
        self.agent_state = "running"
        self.agent_start = time.time()

    def interrupt_agent(self):
        if self.agent:
            try:
                self.agent.kill()
                self.agent.wait(timeout=3)
            except Exception:
                pass
            self.agent = None
        self.agent_state = "interrupted"
        self.msg = "interrupted — type a message / guidance and press Enter to continue   // 已打断——输入引导后回车继续"

    def poll_agent(self):
        if not self.agent:
            return
        # 1) stream the agent's own session log (CoT / tools / drafts)
        try:
            newest = None
            for f in session_logs() - self.sessions_before:
                if newest is None or os.path.getmtime(f) > os.path.getmtime(newest):
                    newest = f
            if newest:
                rc, out = run_capture(["zstd", "-dc", newest], timeout=30)
                lines = out.splitlines() if rc == 0 else []
                seen = self.log_pos.get(newest, 0)
                for ln in lines[seen:]:
                    self._parse_session_line(ln)
                self.log_pos[newest] = len(lines)
        except Exception:
            pass
        # 2) final message on stdout (dedup against what the session log showed)
        if self.agent.poll() is not None:
            try:
                tail = self.agent.stdout.read()
            except Exception:
                tail = ""
            self.agent = None
            self.agent_state = "done"
            if tail.strip():
                shown = False
                for t in self.recent_texts:
                    if t and t in tail:
                        shown = True
                        break
                if not shown:
                    self.add("── agent final ──", "dim")
                    self.add_md(strip_ansi(tail))
                # NOTE: do NOT push the stdout final into recent_texts — that
                # buffer holds SESSION-LOG streamed events only; a later run
                # with identical output must still be shown, not deduped away.
            self.msg = "agent finished — type the next message or press q / Ctrl-C to leave   // 本轮完成——可继续输入，或 q / Ctrl-C 退出"
        elif time.time() - self.agent_start > AGENT_TIMEOUT:
            self.interrupt_agent()
            self.msg = "agent timed out (%ss) — interrupted; type guidance to retry   // 超时已打断；可输入引导重试" % AGENT_TIMEOUT

    def _parse_session_line(self, ln):
        try:
            d = json.loads(ln)
        except Exception:
            return
        t = d.get("type", "")
        data = d.get("data", {}) or {}
        txt = ""
        kind = None
        if t == "reasoning-chunks":
            txt = "".join(data.get("texts") or [data.get("text", "")] or [])
            kind = "reasoning"
        elif t in ("assistant/chunk", "text-chunks"):
            txt = "".join(data.get("texts") or [data.get("text", "")] or [])
            kind = "message"
        elif t == "assistant/message":
            c = data.get("message", {})
            parts = c.get("content") or []
            txt = "".join(x.get("text", "") for x in parts if isinstance(x, dict))
            kind = "message"
        elif t == "tool/call":
            a = data.get("arguments", data.get("input", ""))
            txt = "%s %s" % (data.get("name", "?"), (str(a)[:160] if isinstance(a, str) else ""))
            kind = "tool"
        if txt.strip():
            self.add_agent_event(kind or "message", txt)
            self.recent_texts.append(txt.strip()[:120])

    # ---- drawing -----------------------------------------------------------
    def attr_for(self, name):
        return self.colors.get(name, 0)

    def draw(self):
        scr = self.scr
        h, w = scr.getmaxyx()
        scr.erase()
        # status bar
        status = " doctor-tui | web:%s | phase:%s | agent:%s | %s | %s" % (
            self.web, self.phase, self.agent_state,
            "current:" + self._current_slot(), self._keys_hint(),
        )
        try:
            scr.addstr(0, 0, status[: w - 1], curses.A_REVERSE)
        except curses.error:
            pass
        # message line (2nd from bottom)
        if self.msg:
            try:
                scr.addstr(h - 2, 0, " " + self.msg[: w - 2], self.attr_for("warn"))
            except curses.error:
                pass
        # content pane
        top = 1
        bottom = h - 3 if self.phase != "fix" else h - 3
        view_h = max(bottom - top, 1)
        total = len(self.lines)
        if self.follow:
            self.scroll = max(total - view_h, 0)   # stick to the bottom
        else:
            if self.scroll < 0:
                self.scroll = 0
            if self.scroll > max(total - view_h, 0):
                self.scroll = max(total - view_h, 0)
        for i in range(view_h):
            li = self.scroll + i
            if li >= total:
                break
            spans = self.lines[li]
            x = 0
            for text, attr in spans:
                for ch in text:
                    if x >= w - 1:
                        break
                    try:
                        scr.addstr(top + i, x, ch, attr)
                    except curses.error:
                        pass
                    x += 1
        # input bar
        label = self._input_label()
        prompt = label + self.input
        try:
            scr.addstr(h - 1, 0, prompt[: w - 2], self.attr_for("user"))
            scr.move(h - 1, min(len(prompt), w - 2))
        except curses.error:
            pass
        scr.refresh()

    def _current_slot(self):
        try:
            p = os.path.join(DSH_SOURCE, "current")
            if os.path.islink(p):
                return os.path.basename(os.readlink(p))
            return "?"
        except Exception:
            return "?"

    def _keys_hint(self):
        if self.phase == "fix":
            return "y/n/?/q"
        if self.phase == "llm":
            return "type=msg Enter=send ^C=interrupt/quit PgUp/Dn=scroll"
        return "PgUp/Dn=scroll ^L=clear ^C=quit"

    def _input_label(self):
        if self.phase == "fix":
            return "fix %d/%d (y=apply n=skip ?=detail q=quit) > " % (self.fix_idx + 1, len(self.problems))
        if self.phase == "llm":
            return "you → agent > "
        if self.phase == "restart":
            return "web still down — restart now? (y/n) > "
        return "> "

    # ---- phases ------------------------------------------------------------
    def phase_diag(self):
        self.phase = "diag"
        self.add("── dsh web doctor — interactive TUI ──", "heading")
        self.add("diagnosing (read-only)…   // 正在体检（只读）", "dim")
        rc, out = run_capture(["bash", DOCTOR], timeout=180)
        self.add_md(out)
        rc2, js = run_capture(["bash", DOCTOR, "--diag-json"], timeout=180)
        try:
            info = json.loads(js)
            self.problems = info.get("problems", [])
            self.web = info.get("web", "000")
        except Exception:
            self.problems = []
            self.web = web_code()
        self.msg = "diagnosis done — %d problem(s); fixing one by one   // 体检完成：%d 个问题，逐个修复" % (
            len(self.problems), len(self.problems))

    def phase_fix(self):
        if not self.problems:
            return
        self.phase = "fix"
        self.fix_idx = 0
        while self.fix_idx < len(self.problems):
            self.draw()
            pr = self.problems[self.fix_idx]
            self.add("")
            self.add("[%d/%d] %s" % (self.fix_idx + 1, len(self.problems), pr["hint"]), "warn")
            ans = self._read_input()
            if ans is None:  # quit
                return
            if ans in ("y", "Y", ""):
                self.add("→ running fix…", "dim")
                rc, out = run_capture(["bash", DOCTOR, "--fix-item", pr["id"]], timeout=180)
                self.add_md(out)
                if rc == 0:
                    self.fixed += 1
                else:
                    self.failed += 1
            elif ans in ("n", "N"):
                self.add("→ skipped", "dim")
                self.skipped += 1
            elif ans in ("?", "h", "H"):
                self.add("detail: %s" % pr["hint"], "llm")
                continue
            else:
                self.add("→ quit fixing (applied fixes stay applied)", "dim")
                return
            self.fix_idx += 1
        self.msg = "fixes done — fixed %d / skipped %d / failed %d" % (self.fixed, self.skipped, self.failed)

    def phase_llm(self):
        self.phase = "llm"
        self.agent_state = "idle"
        self._reset_ctx("# dsh doctor self-heal — interactive context\n")
        self._write_ctx("## deterministic pass (already done)\n%s problems: %s\n" % (
            len(self.problems), "; ".join(p["hint"] for p in self.problems)))
        self.add("")
        self.add("── LLM session ──", "heading")
        self.add("The deterministic pass is done. The LLM agent below works on this context:", "dim")
        self.add("type a message and Enter to run it; Ctrl-C interrupts a running agent so you can steer;", "dim")
        self.add("PgUp/PgDn scroll, /help lists keys, /quit leaves.   // 随时输入引导 LLM；Ctrl-C 打断；PgUp/PgDn 滚动", "dim")
        while not self.quit:
            self.web = web_code() if time.time() - self.last_web > 2 else self.web
            self.poll_agent()
            self.draw()
            ch = self._getch(100)
            if ch is not None:
                self._handle(ch)
        self.msg = "leaving LLM session"

    def phase_restart(self):
        self.web = web_code()
        if self.web == "200":
            return
        self.phase = "restart"
        self.add("")
        self.add("web is still DOWN (HTTP %s) — restart it now?" % self.web, "err")
        ans = self._read_input()
        if ans in ("y", "Y", ""):
            self.add("→ relaunching web…", "dim")
            rc, out = run_capture(["bash", DOCTOR, "--fix-item", "web"], timeout=300)
            self.add_md(out)
        else:
            self.add("→ skipped relaunch (run later: dsh-doctor --fix --restart)", "dim")

    def phase_summary(self):
        self.phase = "done"
        self.web = web_code()
        self.add("")
        self.add("── summary ──", "heading")
        self.add("fixed %d / skipped %d / failed %d; web now: %s" % (
            self.fixed, self.skipped, self.failed, "✅ up" if self.web == "200" else "❌ down"), "ok" if self.web == "200" else "err")
        self.add("press q or Ctrl-C to exit   // 按 q 或 Ctrl-C 退出", "dim")

    # ---- input -------------------------------------------------------------
    def _read_input(self):
        """Blocking input for fix/restart prompts. Returns answer or None (quit)."""
        while True:
            self.draw()
            ch = self._getch(None)
            if ch is None:
                continue
            if ch == "KEY_ENTER":
                ans = self.input
                self.input = ""
                return ans
            if ch in ("KEY_QUIT", "KEY_CTRL_C"):
                return None
            if ch == "KEY_ESC":
                self.input = ""
                continue
            if ch in ("KEY_BACKSPACE",):
                self.input = self.input[:-1]
                continue
            if len(ch) == 1:
                self.input += ch

    def _getch(self, timeout):
        self.scr.timeout(timeout if timeout is not None else -1)
        try:
            ch = self.scr.get_wch()
        except curses.error:
            return None
        except KeyboardInterrupt:
            return "KEY_CTRL_C"
        if isinstance(ch, str):
            if ch == "\n" or ch == "\r":
                return "KEY_ENTER"
            if ch == "\x03":
                return "KEY_CTRL_C"
            if ch == "\x1b":
                return "KEY_ESC"
            if ch in ("\x7f", "\x08"):
                return "KEY_BACKSPACE"
            if ch == "\x0c":
                return "KEY_CTRL_L"
            return ch
        return {
            curses.KEY_ENTER: "KEY_ENTER",
            curses.KEY_UP: "KEY_UP",
            curses.KEY_DOWN: "KEY_DOWN",
            curses.KEY_PPAGE: "KEY_PPAGE",
            curses.KEY_NPAGE: "KEY_NPAGE",
            curses.KEY_HOME: "KEY_HOME",
            curses.KEY_END: "KEY_END",
            curses.KEY_BACKSPACE: "KEY_BACKSPACE",
            curses.KEY_RESIZE: "KEY_RESIZE",
        }.get(ch, "KEY_OTHER")

    def _handle(self, ch):
        if ch == "KEY_RESIZE":
            self.draw()
            return
        if ch == "KEY_QUIT" or (ch == "KEY_CTRL_C" and self.agent_state != "running"):
            if self.agent_state == "running":
                return
            self.quit = True
            return
        if ch == "KEY_CTRL_C" and self.agent_state == "running":
            self.interrupt_agent()
            return
        if ch == "KEY_CTRL_L":
            self.clear_pane()
            return
        if ch == "KEY_PPAGE":
            self.follow = False
            self.scroll -= 10
            return
        if ch == "KEY_NPAGE":
            self.follow = False
            self.scroll += 10
            return
        if ch == "KEY_HOME":
            self.follow = False
            self.scroll = 0
            return
        if ch == "KEY_END":
            self.follow = True
            return
        if ch == "KEY_BACKSPACE":
            self.input = self.input[:-1]
            return
        if ch == "KEY_ENTER":
            self._submit()
            return
        if ch == "KEY_ESC":
            self.input = ""
            return
        if isinstance(ch, str) and len(ch) == 1:
            self.input += ch

    def _submit(self):
        text = self.input.strip()
        self.input = ""
        if not text:
            return
        if text == "/quit" or text == "/q":
            self.quit = True
            return
        if text == "/help":
            self._show_help()
            return
        if self.agent_state == "running":
            self.interrupt_agent()
        self._run_llm_turn(text)

    def _show_help(self):
        self.add("── keys ──", "heading")
        self.add("  type + Enter        send a message to the agent   // 输入后回车发送给 LLM", "plain")
        self.add("  Ctrl-C              interrupt a running agent (or quit when idle)", "plain")
        self.add("  PgUp/PgDn/Home/End  scroll the pane", "plain")
        self.add("  Ctrl-L              clear the pane", "plain")
        self.add("  /quit  /q           leave the LLM session", "plain")
        self.add("  /help               this list", "plain")

    def _run_llm_turn(self, text):
        task = self._build_task(text)
        self.add("")
        self.add("── you → agent ──", "user")
        self.add_md(text)
        self._write_ctx("\n## you\n%s\n" % text)
        self.msg = "agent running — Ctrl-C to interrupt   // agent 运行中——Ctrl-C 可打断"
        self.start_agent(task)

    def _build_task(self, user_msg):
        # context file = full conversation so far; the agent sees it all
        with open(CHAT_CTX, "r", encoding="utf-8") as f:
            ctx = f.read()
        task = (
            "You are the dsh web out-of-band self-heal agent, now running as an "
            "INTERACTIVE session steered by the user. The deterministic doctor pass "
            "already ran. Follow the context below. Answer concisely in Chinese. "
            "Discipline: environment noise (deep-check load failures, historical "
            "web.log residue) is NOT proof the slot is broken; verify before acting; "
            "if 3-4 steps make no progress, stop and report what you know, the likely "
            "root cause, and what you need from the user.\n\n--- context ---\n%s\n"
            "\n--- user says now ---\n%s" % (ctx[-8000:], user_msg)
        )
        return task

    def _write_ctx(self, text):
        try:
            with open(CHAT_CTX, "a", encoding="utf-8") as f:
                f.write(text)
        except Exception:
            pass

    def _reset_ctx(self, header):
        # fresh context per session — a stale context would point the agent at
        # the wrong environment (a previous run's diagnosis), wasting its turns
        try:
            with open(CHAT_CTX, "w", encoding="utf-8") as f:
                f.write(header)
        except Exception:
            pass


# ---------------------------------------------------------------------------
def main(scr):
    # raw mode: Ctrl-C arrives as a character through get_wch, NOT as SIGINT
    # to the whole foreground process group — so it interrupts the agent
    # (agent.kill), not the TUI itself. cbreak (the wrapper default) keeps
    # ISIG on and a stray SIGINT can kill the TUI mid-draw.
    curses.raw()
    tui = Tui(scr)
    try:
        tui.phase_diag()
        tui.phase_fix()
        if not tui.quit:
            tui.phase_llm()
        if not tui.quit:
            tui.phase_restart()
            tui.phase_summary()
        tui.draw()
        # wait for quit key
        while not tui.quit:
            ch = tui._getch(None)
            if ch == "KEY_CTRL_C" or ch == "KEY_QUIT" or (isinstance(ch, str) and ch.lower() == "q"):
                break
    except KeyboardInterrupt:
        pass
    finally:
        if tui.agent:
            try:
                tui.agent.kill()
            except Exception:
                pass
        curses.noraw()


def selftest():
    """doctor-tui.py --selftest: render sample markdown without curses."""
    md = Md()
    samples = [
        "# heading one",
        "## heading two",
        "plain **bold** and *italic* and `code` here",
        "> blockquote line",
        "- list item a",
        "- list item b",
        "```bash",
        "echo hello",
        "```",
        "| a | b |",
        "| --- | --- |",
        "| 1 | 2 |",
        "",
        "final **done**",
    ]
    for s in samples:
        print("".join(t for t, _ in md.feed(s)))
    print("SELFTEST OK")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
        sys.exit(0)
    curses.wrapper(main)
