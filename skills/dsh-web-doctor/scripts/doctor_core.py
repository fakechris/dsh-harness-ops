#!/usr/bin/env python3
"""
doctor_core.py — deterministic diagnosis/repair core for dsh-web-doctor.

Structured detector/fixer/verification engine. Every diagnosis produces
CheckResult rows (PASS / FAIL / UNKNOWN + severity + evidence + fix_id + safe
auto-fix flag); health is aggregated from the REQUIRED checks only; each
finding is repaired only by its own mapped fixer; a fixer's success is
confirmed by re-running the associated detector — never by assumption; and a
detector failure is UNKNOWN, never PASS. All report artifacts live in one
private run directory ($TMPDIR/dsh-doctor-<uid>-<pid>-<random>, mode 0700).

The engine never derives user intent or write permission from the problem
count: whether anything may be repaired is decided by the CLI layer (flags /
interactive confirmation), and the deterministic fixers only ever touch the
exact object a finding names.

Out-of-band by design: this module uses only system tools (node, curl, lsof,
zstd, jq) and the skill's own mjs scripts. It loads no DSH compiled package.
"""

from __future__ import annotations

import dataclasses
import datetime as _dt
import enum
import json
import os
import random
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

# ---------------------------------------------------------------------------
# statuses and health
# ---------------------------------------------------------------------------


class CheckStatus(str, enum.Enum):
    """One detector row's outcome. UNKNOWN never folds into PASS."""

    PASS = "PASS"
    FAIL = "FAIL"
    UNKNOWN = "UNKNOWN"


class Severity(str, enum.Enum):
    """Human-prioritization of a finding; health uses required-ness, not severity."""

    INFO = "INFO"
    WARNING = "WARNING"
    ERROR = "ERROR"
    BLOCKING = "BLOCKING"


class Health(str, enum.Enum):
    """Overall web health. HEALTHY is not a terminal state — the TUI owns that."""

    UNASSESSED = "UNASSESSED"
    CHECKING = "CHECKING"
    HEALTHY = "HEALTHY"
    UNVERIFIED = "UNVERIFIED"
    UNHEALTHY = "UNHEALTHY"
    VERIFYING = "VERIFYING"


@dataclasses.dataclass
class CheckResult:
    """One structured finding from one detector."""

    id: str  # detector id, e.g. "http.root"
    status: CheckStatus
    severity: Severity
    summary: str
    evidence: list[str] = dataclasses.field(default_factory=list)
    fix_id: str | None = None  # the ONLY fixer this finding may call
    safe_auto_fix: bool = False  # may --fix run it unattended?
    required: bool = True  # participates in HEALTHY/UNHEALTHY aggregation
    observed_at: float = dataclasses.field(default_factory=time.time)

    def to_dict(self) -> dict[str, object]:
        return {
            "id": self.id,
            "status": self.status.value,
            "severity": self.severity.value,
            "summary": self.summary,
            "evidence": self.evidence,
            "fix_id": self.fix_id,
            "safe_auto_fix": self.safe_auto_fix,
            "required": self.required,
            "observed_at": self.observed_at,
        }


@dataclasses.dataclass
class RepairAttempt:
    """One fixer run plus its re-verification evidence."""

    fix_id: str
    target: str | None  # e.g. the session id or package the finding named
    started_at: float = dataclasses.field(default_factory=time.time)
    finished_at: float | None = None
    ok: bool | None = None  # fixer's own outcome (command succeeded)
    output: list[str] = dataclasses.field(default_factory=list)
    # re-run of the detector that produced the finding; only an all-PASS
    # re-check marks the finding resolved.
    verification: list[CheckResult] = dataclasses.field(default_factory=list)

    @property
    def resolved(self) -> bool | None:
        """True only when verification passed; None while unresolved/unknown."""
        if self.verification:
            return all(check.status is CheckStatus.PASS for check in self.verification)
        return None

    def to_dict(self) -> dict[str, object]:
        return {
            "fix_id": self.fix_id,
            "target": self.target,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "ok": self.ok,
            "output": self.output,
            "verification": [c.to_dict() for c in self.verification],
            "resolved": self.resolved,
        }


# ---------------------------------------------------------------------------
# run context
# ---------------------------------------------------------------------------

DEFAULT_PORT = 3080
REQUIRED_TOOLS = ["node", "curl", "lsof", "zstd", "jq", "ps"]


def resolve_dsh_home(env: dict[str, str] | None = None) -> str:
    env = env or os.environ
    return env.get("DSH_HOME") or str(Path.home() / ".dsh")


class RunContext:
    """All paths and the private run directory one doctor pass uses."""

    def __init__(
        self,
        *,
        dsh_source: str | None = None,
        skills_dir: str | None = None,
        port: int | None = None,
        home: str | None = None,
        cwd: str | None = None,
        run_dir: str | None = None,
        quiet: bool = False,
        env: dict[str, str] | None = None,
    ) -> None:
        self.env = dict(env or os.environ)
        self.home = home or resolve_dsh_home(self.env)
        self.dsh_source = dsh_source or self.env.get("DSH_SOURCE") or os.path.join(self.home, "source")
        self.skills_dir = skills_dir or self.env.get("DSH_SKILLS_DIR") or os.path.join(self.home, "skills")
        self.port = int(port or self.env.get("DSH_WEB_PORT") or DEFAULT_PORT)
        self.cwd = cwd or os.getcwd()
        self.quiet = quiet
        self.scripts_dir = os.path.join(self.skills_dir, "dsh-web-doctor", "scripts")
        self.recovery_dir = os.path.join(self.skills_dir, "dsh-session-recovery", "scripts")
        self.ab_script = os.path.join(self.skills_dir, "dsh-snapshot-ab", "scripts", "ab.sh")
        # Private per-run artifacts; never shared /tmp files.
        if run_dir is None:
            base = self.env.get("TMPDIR") or tempfile.gettempdir()
            run_dir = tempfile.mkdtemp(
                prefix=f"dsh-doctor-{os.getuid() if hasattr(os, 'getuid') else 0}-{os.getpid()}-",
                dir=base,
            )
        self.run_dir = run_dir
        os.chmod(self.run_dir, 0o700)
        self.report_path = os.path.join(self.run_dir, "report.txt")
        self.diag_json_path = os.path.join(self.run_dir, "diag.json")

    # -- helpers -------------------------------------------------------------

    def run(
        self,
        argv: list[str],
        *,
        timeout: float = 60.0,
        stdin: str | None = None,
        cwd: str | None = None,
        env_extra: dict[str, str] | None = None,
    ) -> tuple[int, str, str]:
        """Run one command; returns (exit_code, stdout, stderr). Never raises on a child failure."""
        child_env = dict(self.env)
        if env_extra:
            child_env.update(env_extra)
        try:
            proc = subprocess.run(
                argv,
                input=stdin,
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=cwd or self.cwd,
                env=child_env,
                check=False,
            )
            return proc.returncode, proc.stdout, proc.stderr
        except FileNotFoundError as error:
            return 127, "", f"command not found: {argv[0]}"
        except subprocess.TimeoutExpired as error:
            out = error.stdout.decode() if isinstance(error.stdout, bytes) else (error.stdout or "")
            err = error.stderr.decode() if isinstance(error.stderr, bytes) else (error.stderr or "")
            return 124, out or "", (err or "") + f"\ntimed out after {timeout}s"

    def node(self, script: str, args: list[str] | None = None, **kwargs) -> tuple[int, str, str]:
        return self.run(["node", script, *(args or [])], **kwargs)

    def resolve_slot(self) -> str | None:
        """Resolve $DSH_SOURCE/current to an existing directory, or None."""
        link = os.path.join(self.dsh_source, "current")
        try:
            target = os.path.realpath(link)
        except OSError:
            return None
        return target if os.path.isdir(target) else None

    def session_root(self) -> str:
        return self.env.get("DSH_SESSION_ROOT") or os.path.join(self.home, "sessions")

    def web_log_path(self) -> str:
        return os.path.join(self.dsh_source, "web.log")


# ---------------------------------------------------------------------------
# detectors
# ---------------------------------------------------------------------------

# A detector is `(ctx: RunContext) -> list[CheckResult]`. Register new ones in
# DETECTORS (order is report order); REQUIRED_CHECK_IDS names the checks whose
# PASS/FAIL decide health.


def detect_env_deps(ctx: RunContext) -> list[CheckResult]:
    missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    if missing:
        return [
            CheckResult(
                "env.deps", CheckStatus.FAIL, Severity.BLOCKING,
                f"missing required tools: {', '.join(missing)}",
                evidence=[f"{tool}: not found" for tool in missing],
            )
        ]
    return [CheckResult("env.deps", CheckStatus.PASS, Severity.INFO, "all required tools present")]


def detect_slots(ctx: RunContext) -> list[CheckResult]:
    checks: list[CheckResult] = []
    link = os.path.join(ctx.dsh_source, "current")
    current = ctx.resolve_slot()
    if current is None:
        checks.append(CheckResult(
            "slots.layout", CheckStatus.FAIL, Severity.BLOCKING,
            f"{link} does not resolve to a directory",
            evidence=["no current slot — the A/B layout is missing"],
            fix_id="relink.missing", safe_auto_fix=True,
        ))
    else:
        checks.append(CheckResult(
            "slots.layout", CheckStatus.PASS, Severity.INFO, f"current slot resolves: {current}",
            evidence=[f"{link} -> {current}"],
        ))
    # A/B slot directories: ab-config.json names them, but a plain probe of the
    # two conventional slot names keeps this check dependency-free.
    if os.path.isfile(os.path.join(ctx.dsh_source, "ab-config.json")):
        try:
            with open(os.path.join(ctx.dsh_source, "ab-config.json"), "r") as handle:
                config = json.load(handle)
            slots = [entry.get("dir") for entry in config.get("slots", []) if isinstance(entry, dict)]
            missing_slots = [slot for slot in slots if slot and not os.path.isdir(os.path.join(ctx.dsh_source, slot))]
            if missing_slots:
                checks.append(CheckResult(
                    "slots.layout", CheckStatus.FAIL, Severity.ERROR,
                    "A/B slot directories missing", evidence=[f"missing: {slot}" for slot in missing_slots],
                ))
            elif slots:
                checks[0].evidence.append(f"slots: {', '.join(slots)}")
        except (OSError, ValueError):
            checks.append(CheckResult(
                "slots.layout", CheckStatus.UNKNOWN, Severity.WARNING,
                "ab-config.json unreadable", evidence=["could not parse ab-config.json"],
            ))
    return checks


def detect_launcher(ctx: RunContext) -> list[CheckResult]:
    current = ctx.resolve_slot()
    if current is None:
        return [CheckResult(
            "slots.launcher", CheckStatus.UNKNOWN, Severity.ERROR,
            "no current slot to inspect", required=True,
        )]
    bin_dsh = os.path.join(current, "bin", "dsh")
    cli_js = os.path.join(current, "apps", "cli", "lib", "bin.js")
    if os.path.isfile(bin_dsh) and os.access(bin_dsh, os.X_OK):
        return [CheckResult("slots.launcher", CheckStatus.PASS, Severity.INFO, f"slot launcher present: {bin_dsh}")]
    if os.path.isfile(cli_js):
        return [CheckResult("slots.launcher", CheckStatus.PASS, Severity.INFO, f"compiled CLI entry present: {cli_js}")]
    return [CheckResult(
        "slots.launcher", CheckStatus.FAIL, Severity.ERROR,
        f"current slot has no bootable launcher ({bin_dsh} or {cli_js})",
        fix_id="launcher.missing", safe_auto_fix=True,
    )]


def detect_port(ctx: RunContext) -> list[CheckResult]:
    code, out, err = ctx.run(["lsof", "-tiTCP:" + str(ctx.port), "-sTCP:LISTEN"], timeout=10)
    if code == 127:
        return [CheckResult("port.listener", CheckStatus.UNKNOWN, Severity.WARNING, "lsof unavailable")]
    pids = [line.strip() for line in out.splitlines() if line.strip()]
    if pids:
        return [CheckResult(
            "port.listener", CheckStatus.PASS, Severity.INFO,
            f"listener on :{ctx.port}", evidence=pids[:5],
        )]
    return [CheckResult(
        "port.listener", CheckStatus.FAIL, Severity.ERROR,
        f"nothing listens on :{ctx.port}",
        fix_id="web.down", safe_auto_fix=True,
    )]


def detect_http(ctx: RunContext) -> list[CheckResult]:
    code, out, err = ctx.run(
        ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5",
         f"http://127.0.0.1:{ctx.port}/"],
        timeout=10,
    )
    http_code = out.strip() or "000"
    if http_code == "200":
        return [CheckResult("http.root", CheckStatus.PASS, Severity.INFO, f"HTTP 200 on :{ctx.port}")]
    return [CheckResult(
        "http.root", CheckStatus.FAIL, Severity.BLOCKING,
        f"HTTP {http_code} on :{ctx.port} (expected 200)",
        fix_id="web.down", safe_auto_fix=True,
    )]


def detect_browser(ctx: RunContext) -> list[CheckResult]:
    """Browser acceptance: page errors, error console, plugin load, root render.
    The probe exits 2 when it cannot run (no browser / page unreachable) — that
    is UNKNOWN, never PASS."""
    script = os.path.join(ctx.scripts_dir, "browser-health.mjs")
    if not os.path.isfile(script):
        return [CheckResult("browser.app", CheckStatus.UNKNOWN, Severity.WARNING, "browser-health.mjs missing")]
    code, out, err = ctx.node(script, [], timeout=120)
    if code == 2:
        summary = (out.strip() or err.strip() or "browser probe could not run").splitlines()[-1]
        return [CheckResult("browser.app", CheckStatus.UNKNOWN, Severity.ERROR, f"browser probe unavailable: {summary}")]
    try:
        payload = json.loads(out)
    except json.JSONDecodeError:
        return [CheckResult(
            "browser.app", CheckStatus.UNKNOWN, Severity.ERROR,
            "browser probe produced no parseable result", evidence=[out[:500], err[:500]],
        )]
    status = payload.get("status")
    summary = str(payload.get("summary") or "browser probe")
    evidence = [str(line) for line in (payload.get("evidence") or [])]
    if status == "PASS":
        return [CheckResult("browser.app", CheckStatus.PASS, Severity.INFO, summary, evidence=evidence)]
    if status == "FAIL":
        return [CheckResult("browser.app", CheckStatus.FAIL, Severity.BLOCKING, summary, evidence=evidence)]
    return [CheckResult("browser.app", CheckStatus.UNKNOWN, Severity.ERROR, summary, evidence=evidence)]


def _parse_plugin_deps_output(out: str) -> list[CheckResult]:
    """One finding per missing dependency line; exit 2 (detector failure) is
    handled by the caller and becomes UNKNOWN."""
    checks: list[CheckResult] = []
    evidence_ok: list[str] = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("ok:"):
            evidence_ok.append(line)
        elif line.startswith("FIXABLE:"):
            pkg = _package_from_dep_line(line)
            checks.append(CheckResult(
                "plugin.deps", CheckStatus.FAIL, Severity.ERROR,
                f"plugin dependency missing (fixable): {pkg}",
                evidence=[line], fix_id=f"plugin.dep:{pkg}", safe_auto_fix=True,
            ))
        elif line.startswith("MISSING:"):
            pkg = _package_from_dep_line(line)
            checks.append(CheckResult(
                "plugin.deps", CheckStatus.FAIL, Severity.ERROR,
                f"plugin dependency missing (no fix source): {pkg}",
                evidence=[line], fix_id=None, safe_auto_fix=False,
            ))
    if not checks:
        checks.append(CheckResult(
            "plugin.deps", CheckStatus.PASS, Severity.INFO,
            "all plugin dependencies present", evidence=evidence_ok,
        ))
    return checks


def _package_from_dep_line(line: str) -> str:
    match = re.search(r"(?:FIXABLE|MISSING):\s*([^\s(]+)", line)
    return match.group(1) if match else "?"


def detect_plugin_deps(ctx: RunContext) -> list[CheckResult]:
    script = os.path.join(ctx.scripts_dir, "plugin-deps-check.mjs")
    if not os.path.isfile(script):
        return [CheckResult("plugin.deps", CheckStatus.UNKNOWN, Severity.WARNING, "plugin-deps-check.mjs missing")]
    code, out, err = ctx.node(script, [], timeout=120)
    if code == 2:
        return [CheckResult(
            "plugin.deps", CheckStatus.UNKNOWN, Severity.ERROR,
            "plugin dependency check itself failed (detector failure)",
            evidence=[line for line in err.splitlines() if line.strip()],
        )]
    return _parse_plugin_deps_output(out)


def detect_client_bundle(ctx: RunContext) -> list[CheckResult]:
    script = os.path.join(ctx.scripts_dir, "client-bundle-check.mjs")
    if not os.path.isfile(script):
        return [CheckResult("client.bundle", CheckStatus.UNKNOWN, Severity.WARNING, "client-bundle-check.mjs missing")]
    code, out, err = ctx.node(script, [], timeout=120)
    if code == 2:
        return [CheckResult(
            "client.bundle", CheckStatus.UNKNOWN, Severity.ERROR,
            "client bundle check itself failed (detector failure)",
            evidence=[line for line in err.splitlines() if line.strip()],
        )]
    findings: list[CheckResult] = []
    evidence_ok: list[str] = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("ok:"):
            evidence_ok.append(line)
        elif line.startswith("LEAK:"):
            file = line.split(" ", 1)[1] if " " in line else "?"
            findings.append(CheckResult(
                "client.bundle", CheckStatus.FAIL, Severity.BLOCKING,
                f"browser bundle leaks Node globals: {file}",
                evidence=[line],
                fix_id=f"client.bundle:{file}", safe_auto_fix=False,
            ))
    if not findings:
        findings.append(CheckResult(
            "client.bundle", CheckStatus.PASS, Severity.INFO,
            "all web client bundles are browser-pure", evidence=evidence_ok,
        ))
    return findings


def detect_sessions(ctx: RunContext) -> list[CheckResult]:
    script = os.path.join(ctx.scripts_dir, "session-store-check.mjs")
    if not os.path.isfile(script):
        return [CheckResult("session.files", CheckStatus.UNKNOWN, Severity.WARNING, "session-store-check.mjs missing")]
    code, out, err = ctx.node(script, ["--root", ctx.session_root()], timeout=120)
    if code == 2:
        return [CheckResult("session.files", CheckStatus.UNKNOWN, Severity.ERROR, "session file check failed (detector failure)")]
    if code == 0:
        return [CheckResult("session.files", CheckStatus.PASS, Severity.INFO, "session store file layer healthy")]
    # exit 1: one finding per flagged session, each mapped to its own repair.
    checks: list[CheckResult] = []
    for line in out.splitlines():
        line = line.strip()
        match = re.match(r"FAIL\s+(\S+):", line)
        if match:
            sid = match.group(1)
            checks.append(CheckResult(
                "session.files", CheckStatus.FAIL, Severity.WARNING,
                f"session log corrupt: {sid}", evidence=[line],
                fix_id=f"session.corrupt:{sid}", safe_auto_fix=True,
            ))
    if not checks:
        checks.append(CheckResult(
            "session.files", CheckStatus.FAIL, Severity.WARNING,
            "session file layer flagged problems", evidence=[line for line in out.splitlines() if line.strip()],
        ))
    return checks


def detect_web_logs(ctx: RunContext) -> list[CheckResult]:
    """Current boot-cycle web.log scan: boot-failure markers in the log tail."""
    log_path = ctx.web_log_path()
    if not os.path.isfile(log_path):
        return [CheckResult("web.logs", CheckStatus.UNKNOWN, Severity.INFO, "no web.log to inspect")]
    try:
        stat = os.stat(log_path)
    except OSError as error:
        return [CheckResult("web.logs", CheckStatus.UNKNOWN, Severity.WARNING, f"cannot stat web.log: {error}")]
    if stat.st_size == 0:
        return [CheckResult("web.logs", CheckStatus.UNKNOWN, Severity.INFO, "web.log is empty")]
    try:
        with open(log_path, "r", errors="replace") as handle:
            lines = handle.readlines()
    except OSError as error:
        return [CheckResult("web.logs", CheckStatus.UNKNOWN, Severity.WARNING, f"cannot read web.log: {error}")]
    tail = lines[-200:]
    patterns = [
        r"Cannot find package '[^']+'",
        r"failed to import loader entry [a-zA-Z_-]+",
        r"plugin tree failed to load[^;]*",
        r"process is not defined",
        r"Failed to load plugins?[^.]*",
        r"Uncaught (TypeError|ReferenceError)",
    ]
    matches = [line.strip() for line in tail if any(re.search(p, line) for p in patterns)]
    if matches:
        return [CheckResult(
            "web.logs", CheckStatus.FAIL, Severity.ERROR,
            "current web log tail shows boot/startup errors",
            evidence=matches[-5:],
        )]
    return [CheckResult("web.logs", CheckStatus.PASS, Severity.INFO, "web log tail clean of boot errors")]


def detect_credentials(ctx: RunContext) -> list[CheckResult]:
    """Resolve DEEPSEEK_API_KEY through the real chain: process env →
    $DSH_HOME/.credentials.yaml → project .env → user .env. The value itself is
    never printed. Missing credentials are never auto-generated."""
    found: list[str] = []
    if ctx.env.get("DEEPSEEK_API_KEY"):
        found.append("process environment")
    cred_doc = os.path.join(ctx.home, ".credentials.yaml")
    if os.path.isfile(cred_doc):
        code, out, err = ctx.run(["grep", "-qE", r"(apiKey|DEEPSEEK_API_KEY)\s*[:=]\s*\S+", cred_doc], timeout=10)
        if code == 0:
            found.append(os.path.join(ctx.home, ".credentials.yaml"))
    project_env = os.path.join(ctx.cwd, ".env")
    if os.path.isfile(project_env):
        code, out, err = ctx.run(["grep", "-qE", r"^DEEPSEEK_API_KEY=.+$", project_env], timeout=10)
        if code == 0:
            found.append(f"project .env ({project_env})")
    user_env = os.path.join(ctx.home, ".env")
    if os.path.isfile(user_env):
        code, out, err = ctx.run(["grep", "-qE", r"^DEEPSEEK_API_KEY=.+$", user_env], timeout=10)
        if code == 0:
            found.append("user .env")
    if found:
        return [CheckResult("credentials.chain", CheckStatus.PASS, Severity.INFO,
                            "DEEPSEEK_API_KEY resolves", evidence=[f"source: {source}" for source in found])]
    return [CheckResult(
        "credentials.chain", CheckStatus.FAIL, Severity.ERROR,
        "DEEPSEEK_API_KEY missing from every credential layer",
        evidence=["checked: process env, .credentials.yaml, project .env, user .env"],
        fix_id="credential.missing", safe_auto_fix=False,
    )]


def detect_settings(ctx: RunContext) -> list[CheckResult]:
    """settings.yaml must parse as YAML — existence alone proves nothing."""
    settings_path = os.path.join(ctx.home, "settings.yaml")
    if not os.path.isfile(settings_path):
        return [CheckResult("settings.parse", CheckStatus.UNKNOWN, Severity.INFO, "settings.yaml absent (non-fatal)")]
    code, out, err = ctx.run(["python3", "-c",
                              "import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding='utf-8'))",
                              settings_path], timeout=30)
    if code == 0:
        return [CheckResult("settings.parse", CheckStatus.PASS, Severity.INFO, "settings.yaml parses as YAML")]
    if code == 127 or "No module named 'yaml'" in err:
        return [CheckResult("settings.parse", CheckStatus.UNKNOWN, Severity.WARNING,
                            "cannot verify settings.yaml (no yaml module)", evidence=[err.strip()])]
    return [CheckResult(
        "settings.parse", CheckStatus.FAIL, Severity.WARNING,
        "settings.yaml does not parse as YAML", evidence=[err.strip()],
        fix_id="settings.corrupt", safe_auto_fix=False,
    )]


DETECTORS: dict[str, object] = {
    "env.deps": detect_env_deps,
    "slots.layout": detect_slots,
    "slots.launcher": detect_launcher,
    "port.listener": detect_port,
    "http.root": detect_http,
    "browser.app": detect_browser,
    "plugin.deps": detect_plugin_deps,
    "client.bundle": detect_client_bundle,
    "session.files": detect_sessions,
    "web.logs": detect_web_logs,
    "credentials.chain": detect_credentials,
    "settings.parse": detect_settings,
}

# Ordered detector ids: report order (stable across runs).
DETECTOR_ORDER: list[str] = list(DETECTORS)

# Checks whose PASS/FAIL decide overall health. A required UNKNOWN leaves the
# verdict UNVERIFIED; a required FAIL is UNHEALTHY no matter the rest.
REQUIRED_CHECK_IDS: frozenset[str] = frozenset({
    "env.deps", "slots.layout", "slots.launcher", "port.listener", "http.root",
    "browser.app", "plugin.deps", "client.bundle", "session.files", "web.logs",
    "credentials.chain",
})


def run_detector(ctx: RunContext, detector_id: str) -> list[CheckResult]:
    """Run one detector; an exception is a detector failure (UNKNOWN), never PASS."""
    fn = DETECTORS.get(detector_id)
    if fn is None:
        return [CheckResult(detector_id, CheckStatus.UNKNOWN, Severity.ERROR, "unknown detector")]
    try:
        results = fn(ctx)  # type: ignore[operator]
    except Exception as error:  # noqa: BLE001 — detector failure is a finding
        return [CheckResult(
            detector_id, CheckStatus.UNKNOWN, Severity.ERROR,
            f"detector crashed: {error}",
            evidence=[f"{type(error).__name__}: {error}"],
        )]
    for result in results:
        result.required = result.id in REQUIRED_CHECK_IDS
        if result.required and result.status is CheckStatus.UNKNOWN:
            result.severity = Severity.ERROR
    return results


def run_all_detectors(ctx: RunContext, ids: list[str] | None = None) -> list[CheckResult]:
    checks: list[CheckResult] = []
    for detector_id in ids or DETECTOR_ORDER:
        checks.extend(run_detector(ctx, detector_id))
    return checks


def aggregate_health(checks: list[CheckResult]) -> Health:
    """Required FAIL → UNHEALTHY; no FAIL but required UNKNOWN → UNVERIFIED;
    every required PASS → HEALTHY. Non-required rows never decide health."""
    required = [check for check in checks if check.required]
    if any(check.status is CheckStatus.FAIL for check in required):
        return Health.UNHEALTHY
    if any(check.status is CheckStatus.UNKNOWN for check in required):
        return Health.UNVERIFIED
    return Health.HEALTHY


# ---------------------------------------------------------------------------
# fixers — precise mapping: a finding calls only its own fixer
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class FixerResult:
    ok: bool
    output: list[str]


def _run_fixer(ctx: RunContext, argv: list[str], timeout: float = 300.0) -> FixerResult:
    code, out, err = ctx.run(argv, timeout=timeout)
    lines = [line for line in (out + err).splitlines() if line.strip()]
    return FixerResult(ok=code == 0, output=lines or [f"exit {code}"])


def fix_launcher_missing(ctx: RunContext, target: str | None) -> FixerResult:
    """Materialize the compiled CLI launcher (bin/dsh) into the current slot."""
    current = ctx.resolve_slot()
    if current is None:
        return FixerResult(False, ["no current slot to materialize a launcher into"])
    bin_dsh = os.path.join(current, "bin", "dsh")
    if os.path.isfile(os.path.join(current, "apps", "cli", "lib", "bin.js")):
        os.makedirs(os.path.join(current, "bin"), exist_ok=True)
        launcher = (
            "#!/usr/bin/env bash\n"
            'exec node "$(dirname "$(readlink -f "$0")")/../apps/cli/lib/bin.js" "$@"\n'
        )
        try:
            with open(bin_dsh, "w") as handle:
                handle.write(launcher)
            os.chmod(bin_dsh, 0o755)
        except OSError as error:
            return FixerResult(False, [f"failed to write {bin_dsh}: {error}"])
        return FixerResult(True, [f"materialized {bin_dsh} (compiled CLI entry)"])
    return FixerResult(False, [f"neither {bin_dsh} nor apps/cli/lib/bin.js present; cannot materialize"])


def fix_relink_missing(ctx: RunContext, target: str | None) -> FixerResult:
    """ab.sh status self-heals the extension relinks (idempotent, read-mostly)."""
    if not os.path.isfile(ctx.ab_script):
        return FixerResult(False, [f"ab.sh not found at {ctx.ab_script}"])
    code, out, err = ctx.run(["bash", ctx.ab_script, "status"], timeout=180)
    return FixerResult(code == 0, [line for line in (out + err).splitlines() if line.strip()] or [f"exit {code}"])


def fix_session_corrupt(ctx: RunContext, target: str | None) -> FixerResult:
    """Lossless repair of ONE corrupt session log via the recovery skill."""
    repair = os.path.join(ctx.recovery_dir, "repair-session-log.mjs")
    if target is None:
        return FixerResult(False, ["no session id given"])
    if not os.path.isfile(repair):
        return FixerResult(False, ["repair-session-log.mjs not found — cannot repair sessions"])
    code, out, err = ctx.node(repair, ["--id", target], timeout=180)
    ok = code in (0, 2)  # repair-session-log treats 2 as "valid already"
    return FixerResult(ok, [line for line in (out + err).splitlines() if line.strip()] or [f"exit {code}"])


def fix_plugin_dependency(ctx: RunContext, target: str | None) -> FixerResult:
    """Symlink the slot package dir into the plugin repo's node_modules — the
    exact link plugin-deps-check reported FIXABLE (base package only, never a
    subpath pseudo-entry)."""
    if target is None:
        return FixerResult(False, ["no package given"])
    base = target
    if base.startswith("@"):
        parts = base.split("/")
        base = "/".join(parts[:2])
    else:
        base = base.split("/", 1)[0]
    script = os.path.join(ctx.scripts_dir, "plugin-deps-check.mjs")
    code, out, err = ctx.node(script, [], timeout=120)
    for line in out.splitlines():
        if not line.startswith("FIXABLE:"):
            continue
        match = re.search(r"FIXABLE:\s*([^\s(]+).*repo=(\S+)\s+->\s+(\S+)", line)
        if not match:
            continue
        pkg, repo, src = match.group(1), match.group(2), match.group(3)
        if pkg.split("/", 2)[:2] != base.split("/", 2)[:2] and pkg != base:
            continue
        link = os.path.join(repo, "node_modules", base)
        try:
            os.makedirs(os.path.dirname(link), exist_ok=True)
            if os.path.islink(link) or os.path.exists(link):
                os.unlink(link)
            os.symlink(src, link)
        except OSError as error:
            return FixerResult(False, [f"failed to link {link} -> {src}: {error}"])
        return FixerResult(True, [f"linked {link} -> {src}"])
    return FixerResult(False, [f"no FIXABLE entry for {base} in plugin-deps-check output"])


def fix_web_down(ctx: RunContext, target: str | None) -> FixerResult:
    """Restart the web via the recovery skill's restart script (or built-in)."""
    restart = os.path.join(ctx.recovery_dir, "restart-dsh-web.sh")
    if os.path.isfile(restart):
        code, out, err = ctx.run(["bash", restart], timeout=180)
        return FixerResult(code == 0, [line for line in (out + err).splitlines() if line.strip()] or [f"exit {code}"])
    # built-in fallback: kill listeners on the port, relaunch `dsh web`.
    code, out, err = ctx.run(["lsof", "-tiTCP:" + str(ctx.port), "-sTCP:LISTEN"], timeout=10)
    pids = [line.strip() for line in out.splitlines() if line.strip()]
    for pid in pids:
        ctx.run(["kill", "-TERM", pid], timeout=10)
    deadline = time.time() + 30
    while time.time() < deadline:
        code, out, err = ctx.run(["lsof", "-iTCP:" + str(ctx.port), "-sTCP:LISTEN"], timeout=10)
        if code != 0 or not out.strip():
            break
        time.sleep(1)
    ctx.run(["bash", "-c", f"cd {ctx.home} && nohup dsh web >/tmp/dsh-web-restart.log 2>&1 &"], timeout=10)
    deadline = time.time() + 60
    while time.time() < deadline:
        code, out, err = ctx.run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5",
                                  f"http://127.0.0.1:{ctx.port}/"], timeout=10)
        if out.strip() == "200":
            return FixerResult(True, ["web is UP after built-in restart"])
        time.sleep(2)
    return FixerResult(False, ["web NOT up after restart"])


def fix_credential_missing(ctx: RunContext, target: str | None) -> FixerResult:
    """Credentials are user-owned: never auto-generated. The CLI layer prompts
    interactively and writes ~/.dsh/.env (0600, with a backup); reaching here
    without user input is a caller error."""
    return FixerResult(False, ["credential.missing requires interactive user input; refusing to auto-generate"])


def fix_settings_corrupt(ctx: RunContext, target: str | None) -> FixerResult:
    """Backup and reset a corrupt settings.yaml to {} — user-confirmed only."""
    settings_path = os.path.join(ctx.home, "settings.yaml")
    if not os.path.isfile(settings_path):
        return FixerResult(True, ["settings.yaml absent; nothing to reset"])
    backup = os.path.join(ctx.run_dir, "settings.yaml.corrupt.bak")
    try:
        with open(settings_path, "rb") as src, open(backup, "wb") as dst:
            dst.write(src.read())
        with open(settings_path, "w") as handle:
            handle.write("{}\n")
    except OSError as error:
        return FixerResult(False, [f"failed to reset settings.yaml: {error}"])
    return FixerResult(True, [f"backed up corrupt settings to {backup}; reset to {{}}"])


FIXERS: dict[str, object] = {
    "launcher.missing": fix_launcher_missing,
    "relink.missing": fix_relink_missing,
    "session.corrupt": fix_session_corrupt,
    "plugin.dep": fix_plugin_dependency,
    "web.down": fix_web_down,
    "credential.missing": fix_credential_missing,
    "settings.corrupt": fix_settings_corrupt,
}


def fixer_for(fix_id: str) -> object | None:
    """Map a finding's fix_id to its fixer function (prefix match for
    parametrized ids like session.corrupt:<id> or plugin.dep:<pkg>)."""
    if fix_id is None:
        return None
    fn = FIXERS.get(fix_id)
    if fn is not None:
        return fn
    for key in FIXERS:
        if fix_id.startswith(key + ":"):
            return FIXERS[key]
    return None


def fixer_target(fix_id: str) -> str | None:
    """The parameter of a parametrized fix_id (session id, package name...)."""
    if fix_id is None or ":" not in fix_id:
        return None
    return fix_id.split(":", 1)[1]


# The detector each finding's fixer verification re-runs. fix_id prefix →
# detector id that produced the finding.
FIX_TO_DETECTOR: dict[str, str] = {
    "launcher.missing": "slots.launcher",
    "relink.missing": "slots.layout",
    "session.corrupt": "session.files",
    "plugin.dep": "plugin.deps",
    "web.down": "http.root",
    "credential.missing": "credentials.chain",
    "settings.corrupt": "settings.parse",
}


def verify_finding(ctx: RunContext, fix_id: str) -> list[CheckResult]:
    """Re-run the detector that produced the finding — the only evidence a fix worked."""
    detector_id = FIX_TO_DETECTOR.get(fix_id)
    if detector_id is None:
        return [CheckResult("verify", CheckStatus.UNKNOWN, Severity.WARNING, f"no verification detector for {fix_id}")]
    return run_detector(ctx, detector_id)


def apply_fix(
    ctx: RunContext,
    finding: CheckResult,
    *,
    interactive_credential: bool = False,
) -> RepairAttempt | None:
    """Apply the exact fixer mapped to one finding and verify it. Returns None
    when the finding has no fixer (nothing to do, not an error)."""
    fix_id = finding.fix_id
    fn = fixer_for(fix_id)
    if fn is None:
        return None
    attempt = RepairAttempt(fix_id=fix_id, target=fixer_target(fix_id))
    if fix_id == "credential.missing" and not interactive_credential:
        result = FixerResult(False, ["credential.missing requires interactive user input (--fix-item credential or guided mode)"])
    else:
        try:
            result = fn(ctx, attempt.target)  # type: ignore[operator]
        except Exception as error:  # noqa: BLE001 — a failing fixer is a recorded failure
            result = FixerResult(False, [f"{type(error).__name__}: {error}"])
    attempt.ok = result.ok
    attempt.output = result.output
    attempt.finished_at = time.time()
    attempt.verification = verify_finding(ctx, fix_id)
    return attempt


# ---------------------------------------------------------------------------
# report
# ---------------------------------------------------------------------------


def summarize_health(health: Health, checks: list[CheckResult]) -> str:
    counts = {status: sum(1 for check in checks if check.status is status) for status in CheckStatus}
    return (
        f"health={health.value} "
        f"PASS={counts[CheckStatus.PASS]} FAIL={counts[CheckStatus.FAIL]} "
        f"UNKNOWN={counts[CheckStatus.UNKNOWN]}"
    )


def write_report(ctx: RunContext, checks: list[CheckResult], attempts: list[RepairAttempt]) -> str:
    """Render the text report and the structured diag.json into the run dir."""
    health = aggregate_health(checks)
    lines: list[str] = []
    lines.append(f"dsh-web-doctor report — {_dt.datetime.now().isoformat(timespec='seconds')}")
    lines.append(f"run dir: {ctx.run_dir}")
    lines.append(summarize_health(health, checks))
    lines.append("")
    for check in checks:
        mark = {"PASS": "✅", "FAIL": "❌", "UNKNOWN": "⚠️"}.get(check.status.value, "?")
        lines.append(f"{mark} [{check.id}] {check.status.value} ({check.severity.value}) {check.summary}")
        for evidence in check.evidence:
            lines.append(f"      {evidence}")
        if check.fix_id:
            auto = "auto" if check.safe_auto_fix else "manual"
            lines.append(f"      fix: {check.fix_id} [{auto}]")
    if attempts:
        lines.append("")
        lines.append("== repairs ==")
        for attempt in attempts:
            verdict = ("resolved" if attempt.resolved is True else
                       "unresolved" if attempt.resolved is False else "unverified")
            lines.append(f"* {attempt.fix_id} target={attempt.target or '-'} ok={attempt.ok} -> {verdict}")
            for output in attempt.output:
                lines.append(f"    {output}")
    report = "\n".join(lines) + "\n"
    with open(ctx.report_path, "w") as handle:
        handle.write(report)
    diag = {
        "generated_at": _dt.datetime.now().isoformat(timespec="seconds"),
        "run_dir": ctx.run_dir,
        "health": health.value,
        "checks": [check.to_dict() for check in checks],
        "repairs": [attempt.to_dict() for attempt in attempts],
    }
    with open(ctx.diag_json_path, "w") as handle:
        json.dump(diag, handle, indent=2)
    return report
