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
import locale
import os
import re
import shutil
import subprocess
import sys
import time
import unicodedata
from collections import deque


def display_width(s):
    """Terminal column width: wide/fullwidth chars (CJK) take 2 columns."""
    w = 0
    for ch in s:
        if unicodedata.combining(ch):
            continue
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            w += 2
        else:
            w += 1
    return w


def trunc_width(s, maxw):
    """Cut s to at most maxw terminal columns, never splitting a wide char."""
    out = []
    w = 0
    for ch in s:
        cw = display_width(ch)
        if w + cw > maxw:
            break
        out.append(ch)
        w += cw
    return "".join(out)


# braille 8-dot spinner — "agent is alive & thinking" indicator, like the web
# GUI's live Think row; wide-char safe (each glyph is 1 column)
SPINNERS = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
SPIN_IDX = 0

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


def stream_lines(args, on_line, timeout_total=300):
    """Run args and call on_line(text) for each line as it arrives, so a long
    deterministic pass is VISIBLE progressively (no black screen)."""
    try:
        p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                             text=True, stdin=subprocess.DEVNULL)
        for raw in p.stdout:
            on_line(strip_ansi(raw))
        return p.wait()
    except Exception as e:
        on_line("(cannot stream: %s)\n" % e)
        return 127


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
    def __init__(self, scr, problems_json=None):
        self.problems_json = problems_json
        self.scr = scr
        # UI language: DSH_DOCTOR_LANG (en default, zh available); /lang toggles
        self.lang = os.environ.get("DSH_DOCTOR_LANG", "en")
        if self.lang not in ("en", "zh"):
            self.lang = "en"
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
        self.cursor = 0      # insertion point inside self.input (char index)
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
        self.spin = 0
        self.auto_quit = 0.0   # deadline for auto-exit after a green acceptance; 0 = off

    def bi(self, zh, en):
        """Bilingual prompt: primary language first, the other as a // note."""
        if self.lang == "zh":
            return "%s   // %s" % (zh, en)
        return "%s   // %s" % (en, zh)

    def T(self, zh, en):
        """Single-line title/status text in the primary language only."""
        return zh if self.lang == "zh" else en

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
        self.msg = self.bi("已打断——输入引导后回车继续   // interrupted — type guidance and Enter", "interrupted — type guidance and press Enter to continue   // 已打断——输入引导后回车继续")

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
            # explicit finish verdict — never leave the user guessing what to do
            if not self.problems and self.web == "200":
                self.add("")
                self.add(self.bi("✅ 验收通过：web 正常、无残留问题 — 无需任何操作", "✅ accepted: web up, no leftover problems — nothing to do"), "ok")
                self.add(self.bi("5 秒后自动退出；按任意键或继续输入可取消", "auto-exit in 5s; any key to cancel"), "dim")
                self.auto_quit = time.time() + 5
                self.msg = self.bi("✅ 无问题 — %d 秒后自动退出（按任意键取消）" % 5, "✅ all green — auto-exit in %ds" % 5)
            else:
                self.add("")
                self.add(self.bi(
                    "⚠ agent 完成，但仍有 %d 个问题未解决（web %s）" % (len(self.problems), "正常" if self.web == "200" else "未起"),
                    "⚠ agent done, but %d problem(s) remain (web %s)" % (len(self.problems), "up" if self.web == "200" else "down")), "err")
                self.add(self.bi("继续输入让 LLM 处理，或 q / Ctrl-C 退出", "keep chatting or quit (q / Ctrl-C)"), "dim")
                self.msg = self.bi(
                    "agent 完成 — 还有 %d 个问题；继续输入或 q 退出" % len(self.problems),
                    "agent done — %d problem(s) left; chat on or quit" % len(self.problems))
        elif time.time() - self.agent_start > AGENT_TIMEOUT:
            self.interrupt_agent()
            self.msg = self.bi("超时已打断（%ss）— 输入引导重试" % AGENT_TIMEOUT, "agent timed out (%ss) — interrupted; type guidance to retry" % AGENT_TIMEOUT)

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
        # status bar (primary-language labels; compact — the msg line carries
        # the bilingual detail)
        agent_tag = self.agent_state
        if self.agent_state == "running":
            # advance the spinner on every repaint (~100ms tick) — the pane
            # shows CoT, but during quiet LLM gaps this keeps the "alive"
            # indicator moving like the web GUI's Think row
            self.spin = (self.spin + 1) % len(SPINNERS)
            agent_tag = ("思考中 %s" % SPINNERS[self.spin]) if self.lang == "zh" else ("thinking %s" % SPINNERS[self.spin])
        if self.lang == "zh":
            phases = {"diag": "体检", "autofix": "自动修复", "llm": "LLM", "restart": "重启", "done": "完成"}
            states = {"idle": "空闲", "running": "运行", "interrupted": "已打断", "done": "完成"}
            status = " doctor-tui | web:%s | 阶段:%s | agent:%s | 槽:%s | %s" % (
                self.web, phases.get(self.phase, self.phase), states.get(self.agent_state, agent_tag),
                self._current_slot(), self._keys_hint(),
            )
        else:
            status = " doctor-tui | web:%s | phase:%s | agent:%s | current:%s | %s" % (
                self.web, self.phase, agent_tag,
                self._current_slot(), self._keys_hint(),
            )
        try:
            scr.addstr(0, 0, trunc_width(status, w - 1), curses.A_REVERSE)
        except curses.error:
            pass
        # message line (2nd from bottom)
        if self.msg:
            try:
                scr.addstr(h - 2, 0, trunc_width(" " + self.msg, w - 2), self.attr_for("warn"))
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
                    x += display_width(ch)   # wide chars (CJK) take 2 columns
        # input bar (cursor column accounts for wide chars + insertion point)
        label = self._input_label()
        prompt = label + self.input
        curs_col = display_width(label) + display_width(self.input[:self.cursor])
        try:
            scr.addstr(h - 1, 0, trunc_width(prompt, w - 2), self.attr_for("user"))
            scr.move(h - 1, min(curs_col, w - 2))
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
        if self.lang == "zh":
            if self.phase == "llm":
                return "输入=指引 回车=发送 ^C=打断/退出 PgUp/Dn=滚动"
            return "PgUp/Dn=滚动 ^L=清屏 ^C=退出"
        if self.phase == "llm":
            return "type=steer Enter=send ^C=interrupt/quit PgUp/Dn=scroll"
        return "PgUp/Dn=scroll ^L=clear ^C=quit"

    def _input_label(self):
        if self.phase == "llm":
            if self.lang == "zh":
                return "你 → agent（回车=发送 ^C=打断 /help）> "
            return "you → agent (Enter=send ^C=interrupt /help) > "
        if self.phase == "restart":
            return self.bi("web 仍未起 — 现在重启？(y/n) > ", "web still down — restart now? (y/n) > ")
        return "> "

    # ---- phases ------------------------------------------------------------
    def phase_diag(self):
        self.phase = "diag"
        self.add("── dsh web doctor — interactive TUI ──", "heading")
        if self.problems_json:
            # run_guided already streamed the diagnosis into the terminal and
            # handed us the structured result — never re-run, never black-screen
            try:
                with open(self.problems_json, "r", encoding="utf-8") as f:
                    info = json.load(f)
                self.problems = info.get("problems", [])
                self.web = info.get("web", "000")
            except Exception:
                self.problems = []
                self.web = web_code()
            self.add(self.bi(
                "确定性诊断已在上方终端输出 — 发现 %d 个问题" % len(self.problems),
                "deterministic diagnosis ran above in the terminal — %d problem(s) found" % len(self.problems)),
                "dim" if not self.problems else "warn")
            return
        # direct invocation without run_guided: stream the diagnosis INTO the
        # pane line by line so it is never a frozen wait
        self.add(self.bi("正在体检（流式）…", "diagnosing (streaming)…"), "dim")

        def on_line(line):
            self.add_md(line)
            self.draw()   # repaint so the line is VISIBLE as it streams in

        stream_lines(["bash", DOCTOR], on_line)
        rc2, js = run_capture(["bash", DOCTOR, "--diag-json"], timeout=180)
        try:
            info = json.loads(js)
            self.problems = info.get("problems", [])
            self.web = info.get("web", "000")
        except Exception:
            self.problems = []
            self.web = web_code()

    def phase_autofix(self):
        """Deterministic known issues are FIXED AUTOMATICALLY — no per-item
        confirmation. The user does not decide each fix; they watch the LLM's
        CoT and interrupt only when something looks wrong. If the deterministic
        pass cannot resolve something, the LLM phase takes over."""
        if not self.problems:
            self.add(self.bi("✅ 0 问题 — 无需确定性修复", "✅ 0 problems — nothing to fix"), "ok")
            return
        self.phase = "autofix"
        self.add("")
        self.add(self.T("── 确定性自动修复 ──", "── deterministic auto-fix ──"), "heading")
        self.add(self.bi(
            "%d 个已知问题 — 自动修复中（可逆、带备份；随后在 LLM 阶段监督 CoT）" % len(self.problems),
            "%d known issue(s) — auto-fixing (reversible, backed up; supervise the CoT in the LLM phase)" % len(self.problems)), "dim")

        def on_line(line):
            self.add_md(line)
            self.draw()   # repaint so the fix output streams visibly

        rc = stream_lines(["bash", DOCTOR, "--fix"], on_line)
        # re-verify after the deterministic pass
        rc2, js = run_capture(["bash", DOCTOR, "--diag-json"], timeout=180)
        try:
            info = json.loads(js)
            self.problems = info.get("problems", [])
            self.web = info.get("web", "000")
        except Exception:
            pass
        if not self.problems:
            self.add(self.bi("✅ 确定性修复完成：全部解决", "✅ deterministic fix complete"), "ok")
        else:
            self.add(self.bi("%d 个问题残留 — 交给 LLM 自动诊断修复" % len(self.problems),
                            "%d problem(s) left — the LLM will diagnose & fix" % len(self.problems)), "warn")

    def phase_llm(self):
        """The LLM runs AUTONOMOUSLY (0 problems → read-only acceptance check;
        problems left → diagnose & fix). The user's job is to WATCH the CoT and
        interrupt with guidance when something looks wrong — not to approve each
        step. The agent only asks the user when it genuinely cannot decide."""
        self.phase = "llm"
        self.agent_state = "idle"
        self._reset_ctx("# dsh doctor self-heal — interactive context\n")
        self._write_ctx("## deterministic pass (done)\n%s problems remaining: %s\n" % (
            len(self.problems), "; ".join(p["hint"] for p in self.problems)))
        self.add("")
        self.add(self.T("── LLM 会话 ──", "── LLM session ──"), "heading")
        if not self.problems:
            self.add(self.bi(
                "✅ 体检 0 问题 / web %s — LLM 自动交叉验证中…" % ("正常" if self.web == "200" else "未起(HTTP %s)" % self.web),
                "✅ 0 problems / web %s — LLM auto cross-checking…" % ("up" if self.web == "200" else "down (HTTP %s)" % self.web)), "ok")
        else:
            self.add(self.bi(
                "%d 个问题残留 — LLM 自动诊断修复中…" % len(self.problems),
                "%d problem(s) left — the LLM is diagnosing & fixing…" % len(self.problems)), "warn")
        self.add(self.bi(
            "你随时可以：Ctrl-C 打断并输入指引 / 直接输入消息回车（会先打断）→ 引导 LLM",
            "anytime: Ctrl-C interrupts a running agent; type + Enter steers it (interrupts first)"), "dim")
        self.add(self.bi("PgUp/PgDn 滚动看完整 CoT · /help · /quit",
                         "PgUp/PgDn scroll the full CoT · /help · /quit"), "dim")
        self._auto_start()
        while not self.quit:
            self.web = web_code() if time.time() - self.last_web > 2 else self.web
            self.poll_agent()
            if self.auto_quit:
                left = int(self.auto_quit - time.time())
                if left <= 0:
                    self.add("")
                    self.add(self.bi("✅ 无问题，自动退出 — 如需再次体检：dsh-doctor --guide",
                                      "✅ all green, auto-exiting — re-run dsh-doctor --guide anytime"), "ok")
                    self.quit = True
                    break
                if left != getattr(self, "_last_left", -1):
                    self._last_left = left
                    self.msg = self.bi("✅ 无问题 — %d 秒后自动退出（按任意键取消）" % left,
                                        "✅ all green — auto-exit in %ds" % left)
            self.draw()
            ch = self._getch(100)
            if ch is not None:
                if self.auto_quit:
                    self.auto_quit = 0.0
                    self.msg = self.bi("自动退出已取消 — 可继续对话；q / Ctrl-C 退出", "auto-exit cancelled — keep chatting; q / Ctrl-C to leave")
                self._handle(ch)
        self.msg = self.bi("正在退出 LLM 会话", "leaving LLM session")

    def _auto_start(self):
        if self.agent_state == "running":
            return
        self.add("")
        self.add(self.T("── 自动运行：LLM 自愈/验收（CoT 实时渲染）──", "── auto-run: LLM self-heal/acceptance (CoT live) ──"), "user")
        self.msg = self.bi("agent 自动运行中 — Ctrl-C 可打断并输入指引", "agent auto-running — Ctrl-C to interrupt & steer")
        self.start_agent(self._build_task(""))

    def phase_restart(self):
        self.web = web_code()
        if self.web == "200":
            return
        self.phase = "restart"
        self.add("")
        self.add(self.bi(
            "web 仍未起（HTTP %s）— 自动重启中…（重启是 doctor 的本职，可逆）" % self.web,
            "web still down (HTTP %s) — auto-restarting… (relaunching is the doctor's job, reversible)" % self.web), "err")
        self.add(self.bi("→ 正在重启 web…", "→ relaunching web…"), "dim")
        rc, out = run_capture(["bash", DOCTOR, "--fix-item", "web"], timeout=300)
        self.add_md(out)

    def phase_summary(self):
        self.phase = "done"
        self.web = web_code()
        self.add("")
        self.add(self.T("── 汇总 ──", "── summary ──"), "heading")
        if not self.problems:
            self.add(self.bi("✅ 无残留问题；web：%s" % ("正常" if self.web == "200" else "未起"),
                             "✅ no leftover problems; web: %s" % ("up" if self.web == "200" else "down")),
                     "ok" if self.web == "200" else "err")
        else:
            self.add(self.bi("%d 问题未解决；web：%s" % (len(self.problems), "正常" if self.web == "200" else "未起"),
                             "%d problem(s) unresolved; web: %s" % (len(self.problems), "up" if self.web == "200" else "down")), "err")
            self.add(self.bi("提示：可重新运行 dsh-doctor --guide 或 --agent 继续；或 /help 后继续对话",
                             "tip: re-run dsh-doctor --guide or --agent, or keep chatting (/help)"), "dim")
        self.add(self.bi("按 q 或 Ctrl-C 退出", "press q or Ctrl-C to exit"), "dim")

    # ---- input -------------------------------------------------------------
    def _read_esc_sequence(self):
        """macOS ncurses delivers ESC[<X> as SEPARATE chars even with keypad on
        (verified 2026-08-13) — combine them here so ←/→/Home/End work, and a
        lone ESC no longer arrives as a stray char that clears the input."""
        esc_map = {"A": "KEY_UP", "B": "KEY_DOWN", "C": "KEY_RIGHT",
                   "D": "KEY_LEFT", "H": "KEY_HOME", "F": "KEY_END"}
        try:
            self.scr.timeout(60)   # short window for the rest of the sequence
            nxt = self.scr.get_wch()
        except curses.error:
            return "KEY_ESC"       # lone ESC
        if not isinstance(nxt, str) or nxt not in ("[", "O"):
            return "KEY_ESC"
        try:
            self.scr.timeout(60)
            final = self.scr.get_wch()
        except curses.error:
            return "KEY_ESC"
        if isinstance(final, str) and final in esc_map:
            return esc_map[final]
        return "KEY_ESC"

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
                return self._read_esc_sequence()
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
            curses.KEY_LEFT: "KEY_LEFT",
            curses.KEY_RIGHT: "KEY_RIGHT",
            curses.KEY_DC: "KEY_DC",
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
        # HOME/END edit the INPUT cursor (the input bar is the focus; pane
        # scrolling is PgUp/PgDn, End-to-bottom is the default follow mode)
        if ch == "KEY_BACKSPACE":
            if self.cursor > 0:
                self.input = self.input[:self.cursor - 1] + self.input[self.cursor:]
                self.cursor -= 1
            return
        if ch == "KEY_DC":
            if self.cursor < len(self.input):
                self.input = self.input[:self.cursor] + self.input[self.cursor + 1:]
            return
        if ch == "KEY_LEFT":
            if self.cursor > 0:
                self.cursor -= 1
            return
        if ch == "KEY_RIGHT":
            if self.cursor < len(self.input):
                self.cursor += 1
            return
        if ch == "KEY_HOME":
            self.cursor = 0
            return
        if ch == "KEY_END":
            self.cursor = len(self.input)
            return
        if ch == "KEY_ENTER":
            self._submit()
            return
        if ch == "KEY_ESC":
            return   # lone ESC: no-op — never wipe the typed message
        if isinstance(ch, str) and len(ch) >= 1:
            # insert at the cursor (unicode-safe: CJK arrives as one char)
            self.input = self.input[:self.cursor] + ch + self.input[self.cursor:]
            self.cursor += 1

    def _submit(self):
        text = self.input.strip()
        self.input = ""
        self.cursor = 0
        if not text:
            return
        if text == "/quit" or text == "/q":
            self.quit = True
            return
        if text == "/help":
            self._show_help()
            return
        if text == "/lang":
            self.lang = "zh" if self.lang == "en" else "en"
            self.add(self.bi("语言已切换为中文（主语言）", "switched to English (primary)"), "ok")
            return
        if self.agent_state == "running":
            self.interrupt_agent()
        self._run_llm_turn(text)

    def _show_help(self):
        self.add(self.T("── 按键 ──", "── keys ──"), "heading")
        self.add(self.bi("  输入 + 回车        给 LLM 发消息/指引（运行中会先打断）",
                         "  type + Enter       send a message to the agent (interrupts first)"), "plain")
        self.add(self.bi("  ←/→ Home/End       移动输入光标（行内编辑）",
                         "  ←/→ Home/End       move the input cursor (mid-text editing)"), "plain")
        self.add(self.bi("  ⌫ / Delete         删除光标前/后", "  ⌫ / Delete          delete before/after the cursor"), "plain")
        self.add(self.bi("  Ctrl-C              打断运行中的 agent（空闲时退出）",
                         "  Ctrl-C              interrupt a running agent (or quit when idle)"), "plain")
        self.add(self.bi("  PgUp/PgDn           滚动回看 CoT", "  PgUp/PgDn           scroll the pane"), "plain")
        self.add(self.bi("  Ctrl-L              清屏", "  Ctrl-L              clear the pane"), "plain")
        self.add(self.bi("  /quit  /q           退出 LLM 会话", "  /quit  /q           leave the LLM session"), "plain")
        self.add(self.bi("  /lang               切换语言 / switch language", "  /lang               switch language"), "plain")
        self.add(self.bi("  /help               本帮助", "  /help               this list"), "plain")

    def _run_llm_turn(self, text):
        task = self._build_task(text)
        self.add("")
        self.add(self.T("── 你 → agent ──", "── you → agent ──"), "user")
        self.add_md(text)
        self._write_ctx("\n## you\n%s\n" % text)
        self.msg = "agent running — Ctrl-C to interrupt   // agent 运行中——Ctrl-C 可打断"
        self.start_agent(task)

    def _build_task(self, user_msg):
        # context file = full conversation so far; the agent sees it all
        with open(CHAT_CTX, "r", encoding="utf-8") as f:
            ctx = f.read()
        n_problems = len(self.problems)
        if n_problems == 0:
            mode = ("你面对的是“全绿”体检：0 问题、web 正常。你的任务是**只读独立交叉验证**"
                    "（curl 3080 / launcher 链 / 扩展 relink / ~/.dsh/.env 的 key / web.log），"
                    "确认健康后输出“✅ 验收通过”＋你验证过的证据清单；发现报告漏掉的问题再报。"
                    "不要修改任何文件、不重启任何进程。")
        else:
            mode = ("体检还剩 %d 个问题（见 context）。你的任务是**自动诊断根因并修复**："
                    "优先复用确定性原语（bash doctor.sh --fix / --fix-item <kind>），每步验证；"
                    "修完后验证 web 200。**只有当你无法判断/需要用户决策时才停下来问**"
                    "（例如缺 API key、不确定某个删除/改动）。" % n_problems)
        if user_msg:
            user_part = "\n\n--- 用户此刻的指引（打断消息）---\n" + user_msg
        else:
            user_part = "\n\n（暂无用户输入——按上述模式自主运行；用户在 TUI 里看你的完整 CoT，可能随时打断）"
        task = (
            "你是 dsh web 的 out-of-band 自愈/验收 agent，处于用户监督的交互会话（TUI）中。"
            "确定性体检已完成（结果见 context）。" + mode +
            "\n纪律（0813 教训，必须遵守）：确定性报告里的某些 \"unavailable / 失败\" 可能是环境性噪音"
            "（deep check 的 compiled reader 加载失败、web.log 历史残留）——**不是槽坏了的证据**，先看具体报错再下结论；"
            "连续 3-4 步没有进展就停止深挖，输出：已查证的事实、最可能的根因、卡点、需要用户决策什么。"
            "用户在看你的完整 CoT；用户随时会打断并输入指引，按指引调整方向。"
            "回答用简洁中文。"
            "\n\n--- context ---\n%s%s" % (ctx[-8000:], user_part)
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
def main(scr, problems_json=None):
    # UTF-8 locale first — without it curses reads CJK input byte-wise and
    # wide-char rendering misaligns (2026-08-13: Chinese input/editing broke)
    try:
        locale.setlocale(locale.LC_ALL, "")
    except Exception:
        pass
    # raw mode: Ctrl-C arrives as a character through get_wch, NOT as SIGINT
    # to the whole foreground process group — so it interrupts the agent
    # (agent.kill), not the TUI itself. cbreak (the wrapper default) keeps
    # ISIG on and a stray SIGINT can kill the TUI mid-draw.
    curses.raw()
    tui = Tui(scr, problems_json=problems_json)
    try:
        tui.phase_diag()
        tui.phase_autofix()
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
    problems_json = None
    if "--problems-json" in sys.argv:
        i = sys.argv.index("--problems-json")
        if i + 1 < len(sys.argv):
            problems_json = sys.argv[i + 1]
    curses.wrapper(main, problems_json)
