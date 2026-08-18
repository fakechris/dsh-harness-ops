#!/usr/bin/env python3
"""
doctor.py — dsh-web-doctor CLI over the deterministic core (doctor_core.py).

Flag compatibility with the legacy doctor.sh entry (doctor.sh is now a thin
`exec python3 doctor.py "$@"`):

  doctor.py                 diagnose only (read-only)
  doctor.py --diag-json     structured JSON (health + every check) on stdout
  doctor.py --fix           deterministic auto-fix (safe fixers, each verified)
  doctor.py --fix --restart fix, then relaunch the web
  doctor.py --fix-item <id> run ONE fixer (credentials prompt allowed)
  doctor.py --guide         mini TUI (the existing curses surface for now;
                            the event-driven rewrite is PR 4)
  doctor.py --agent         LLM one-shot (dsh --profile headless) + full re-check
  doctor.py --quiet         less chatter

Exit codes: 0 = healthy (or fixed+verified); 1 = problems remain; 2 = web not
up after restart. Detector failures are UNKNOWN findings, never silence.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import doctor_core as core  # noqa: E402


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="dsh-doctor",
        description="out-of-band diagnosis, repair and relaunch for dsh web",
    )
    parser.add_argument("--fix", action="store_true", help="deterministic auto-fix (safe fixers only)")
    parser.add_argument("--restart", action="store_true", help="relaunch the web after fixing")
    parser.add_argument("--force", action="store_true", help="with --agent: allow unattended repair")
    parser.add_argument("--fix-item", metavar="FIX_ID", help="run exactly one fixer (e.g. credential.missing)")
    parser.add_argument("--guide", "--tui", dest="guide", action="store_true", help="mini TUI (interactive)")
    parser.add_argument("--agent", action="store_true", help="LLM self-heal via headless one-shot")
    parser.add_argument("--diag-json", action="store_true", help="print structured diagnosis JSON to stdout")
    parser.add_argument("--quiet", action="store_true", help="less chatter")
    parser.add_argument("--selftest", action="store_true", help=argparse.SUPPRESS)
    return parser.parse_args(argv)


def say(ctx: core.RunContext, message: str, *, json_mode: bool = False) -> None:
    """Progress chatter. In --diag-json mode stdout carries ONLY the JSON, so
    chatter goes to stderr there."""
    if ctx.quiet:
        return
    if json_mode:
        sys.stderr.write(message + "\n")
    else:
        print(message)


def build_problems_payload(ctx: core.RunContext, checks: list[core.CheckResult]) -> dict[str, object]:
    """The {problems:[{hint}], web} shape the legacy TUI consumes."""
    web = "000"
    for check in checks:
        if check.id == "http.root":
            match = next((line for line in check.evidence if "HTTP" in line), None)
            if match:
                for token in match.split():
                    if token.startswith("HTTP") and token[4:].isdigit():
                        web = token[4:]
    hints = [
        {"id": check.id, "hint": check.summary, "fix_id": check.fix_id, "safe_auto_fix": check.safe_auto_fix}
        for check in checks
        if check.status is core.CheckStatus.FAIL
    ]
    return {"problems": hints, "web": web}


def run_agent(ctx: core.RunContext, report_text: str, force: bool) -> tuple[bool, list[str]]:
    """LLM self-heal: one headless one-shot with the deterministic report as
    context. Returns (ok, output_lines). The caller re-diagnoses afterwards."""
    dsh = os.path.join(ctx.resolve_slot() or "", "bin", "dsh")
    if not os.path.isfile(dsh):
        dsh = "dsh"
    instructions = (
        "你是 dsh-web-doctor 的 LLM 检修脑。以下是确定性诊断报告（只读体检 + 已执行的修复）。"
        "请：1) 基于报告根因判断，能复用确定性原语（dsh-doctor --fix / --fix-item <id>）就复用；"
        "2) 每步修复后验证；3) 只有需要用户决策时才停下来问（如缺 API key、不确定某个删除）。"
        "4) 不要臆造凭据。\n\n"
        + report_text
        + "\n\n修复完成后执行 dsh-doctor --diag-json 确认全部 PASS。"
    )
    timeout = float(os.environ.get("DSH_DOCTOR_AGENT_TIMEOUT", "600"))
    env = dict(ctx.env)
    env["DSH_PERMISSION_MODE"] = "danger-full-access"
    lines: list[str] = []
    try:
        proc = subprocess.Popen(
            [dsh, "--profile", "headless", instructions],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env,
        )
        deadline = time.monotonic() + timeout
        assert proc.stdout is not None
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                proc.kill()
                lines.append(f"agent timed out after {int(timeout)}s")
                return False, lines
            line = proc.stdout.readline()
            if not line:
                break
            line = line.rstrip("\n")
            if line:
                lines.append(line)
                say(ctx, f"  agent: {line}")
        code = proc.wait(timeout=30)
        return code == 0, lines
    except Exception as error:  # noqa: BLE001
        lines.append(f"agent launch failed: {error}")
        return False, lines


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv if argv is not None else sys.argv[1:])
    if args.selftest:
        print("doctor.py selftest OK")
        return 0
    ctx = core.RunContext(quiet=args.quiet)

    say(ctx, f"dsh-web-doctor (out-of-band) — port {ctx.port}", json_mode=args.diag_json)

    # ── diagnose ──────────────────────────────────────────────────────────────
    checks = core.run_all_detectors(ctx)
    attempts: list[core.RepairAttempt] = []
    health = core.aggregate_health(checks)

    # ── single fixer (--fix-item) ─────────────────────────────────────────────
    if args.fix_item:
        fix_id = args.fix_item
        finding = next(
            (check for check in checks if check.fix_id == fix_id),
            core.CheckResult("manual", core.CheckStatus.FAIL, core.Severity.ERROR, "manual fixer run",
                             fix_id=fix_id, safe_auto_fix=False),
        )
        interactive = fix_id == "credential.missing"
        attempt = core.apply_fix(ctx, finding, interactive_credential=interactive)
        if attempt is not None:
            attempts.append(attempt)
            checks = core.run_all_detectors(ctx)
            health = core.aggregate_health(checks)

    # ── deterministic auto-fix (--fix) ────────────────────────────────────────
    if args.fix and not args.fix_item:
        say(ctx, "== auto-fix (safe fixers only) ==")
        for check in checks:
            if check.status is not core.CheckStatus.FAIL:
                continue
            if not check.safe_auto_fix or check.fix_id is None:
                continue
            # Web relaunch is opt-in via --restart (legacy --fix semantics);
            # the --restart branch below owns the web.down fixer.
            if check.fix_id == "web.down":
                continue
            attempt = core.apply_fix(ctx, check)
            if attempt is not None:
                attempts.append(attempt)
                say(ctx, f"  {check.fix_id}: {'resolved' if attempt.resolved is True else 'NOT resolved'}")
        # Refresh the full diagnosis so the report reflects the post-fix state
        # (repair attempts remain recorded with their own verification).
        checks = core.run_all_detectors(ctx)
        health = core.aggregate_health(checks)

    # ── restart (--restart) ───────────────────────────────────────────────────
    if args.restart:
        say(ctx, "== relaunching dsh web ==")
        web_finding = next((c for c in checks if c.id == "http.root"), None)
        if web_finding is None or web_finding.status is not core.CheckStatus.PASS:
            attempt = core.apply_fix(ctx, web_finding or core.CheckResult(
                "http.root", core.CheckStatus.FAIL, core.Severity.BLOCKING, "web down", fix_id="web.down",
                safe_auto_fix=True,
            ))
            if attempt is not None:
                attempts.append(attempt)
                health = core.aggregate_health(core.run_all_detectors(ctx))
                if health is core.Health.UNHEALTHY and any(
                    attempt.fix_id == "web.down" and attempt.resolved is not True for attempt in attempts):
                    say(ctx, "web NOT up after restart")
                    return 2
        else:
            say(ctx, "  web already up — skipping restart")

    # ── LLM agent (--agent) ───────────────────────────────────────────────────
    if args.agent and not args.fix_item:
        report_text = core.write_report(ctx, checks, attempts)
        say(ctx, "== LLM self-heal (headless one-shot) ==")
        _, _lines = run_agent(ctx, report_text, args.force)
        say(ctx, "== full re-check after agent ==")
        checks = core.run_all_detectors(ctx)
        attempts = []
        health = core.aggregate_health(checks)

    # ── report / output ───────────────────────────────────────────────────────
    report_text = core.write_report(ctx, checks, attempts)
    if args.diag_json:
        with open(ctx.diag_json_path, "r") as handle:
            sys.stdout.write(handle.read())
        return 0 if health is core.Health.HEALTHY else 1
    if args.guide:
        problems_path = os.path.join(ctx.run_dir, "tui-problems.json")
        with open(problems_path, "w") as handle:
            json.dump(build_problems_payload(ctx, checks), handle)
        # PR 4: the event-driven TUI (doctor_tui.py) replaces the legacy
        # curses surface; it drives the controller itself, so only the run dir
        # is passed for diagnostics.
        tui = os.path.join(ctx.scripts_dir, "doctor_tui.py")
        if os.path.isfile(tui):
            say(ctx, f"deterministic diagnosis finished — {len([c for c in checks if c.status is core.CheckStatus.FAIL])} problem(s); launching TUI")
            subprocess.run(["python3", tui], check=False)
        else:
            say(ctx, "doctor_tui.py missing — falling back to text report")
            print(report_text)
        return 0
    print(report_text, end="")

    if health is core.Health.HEALTHY:
        return 0
    if health is core.Health.UNVERIFIED:
        say(ctx, "verdict UNVERIFIED — required checks unknown; nothing failed but health is not proven")
        return 1
    return 1


if __name__ == "__main__":
    sys.exit(main())
