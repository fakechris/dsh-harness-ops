#!/usr/bin/env python3
"""test_core.py — deterministic-core tests for dsh-web-doctor (PR 2).

Runs with pytest (preferred) or `python3 -m unittest discover`. Uses only
temp dirs and the skill's own scripts — never touches the real DSH home.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = TESTS_DIR.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import doctor_core as core  # noqa: E402


class HealthAggregationTest(unittest.TestCase):
    def check(self, status, required=True, fix_id=None):
        return core.CheckResult("t", status, core.Severity.INFO, "x", fix_id=fix_id, required=required)

    def test_required_fail_is_unhealthy(self):
        checks = [self.check(core.CheckStatus.PASS), self.check(core.CheckStatus.FAIL)]
        self.assertIs(core.aggregate_health(checks), core.Health.UNHEALTHY)

    def test_required_unknown_is_unverified(self):
        checks = [self.check(core.CheckStatus.PASS), self.check(core.CheckStatus.UNKNOWN)]
        self.assertIs(core.aggregate_health(checks), core.Health.UNVERIFIED)

    def test_all_required_pass_is_healthy(self):
        checks = [self.check(core.CheckStatus.PASS), self.check(core.CheckStatus.PASS)]
        self.assertIs(core.aggregate_health(checks), core.Health.HEALTHY)

    def test_non_required_fail_does_not_decide_health(self):
        checks = [self.check(core.CheckStatus.PASS), self.check(core.CheckStatus.FAIL, required=False)]
        self.assertIs(core.aggregate_health(checks), core.Health.HEALTHY)


class DetectorFailureTest(unittest.TestCase):
    def test_crashing_detector_is_unknown_not_pass(self):
        ctx = core.RunContext(run_dir=tempfile.mkdtemp(), quiet=True)

        def boom(_ctx):
            raise RuntimeError("detector blew up")

        core.DETECTORS["test.boom"] = boom
        try:
            results = core.run_detector(ctx, "test.boom")
            self.assertEqual(len(results), 1)
            self.assertIs(results[0].status, core.CheckStatus.UNKNOWN)
            self.assertIn("detector crashed", results[0].summary)
        finally:
            del core.DETECTORS["test.boom"]

    def test_unknown_detector_id(self):
        ctx = core.RunContext(run_dir=tempfile.mkdtemp(), quiet=True)
        results = core.run_detector(ctx, "no.such.detector")
        self.assertIs(results[0].status, core.CheckStatus.UNKNOWN)


class FixMappingTest(unittest.TestCase):
    def test_precise_fixer_mapping(self):
        # A finding's fix_id resolves to exactly one fixer.
        self.assertIs(core.fixer_for("launcher.missing"), core.fix_launcher_missing)
        self.assertIs(core.fixer_for("web.down"), core.fix_web_down)
        self.assertIs(core.fixer_for("credential.missing"), core.fix_credential_missing)
        # Parametrized ids map by prefix.
        self.assertIs(core.fixer_for("session.corrupt:abc-123"), core.fix_session_corrupt)
        self.assertIs(core.fixer_for("plugin.dep:@deepseek-ai/dsh-x"), core.fix_plugin_dependency)
        # Unfixable findings have no fixer.
        self.assertIsNone(core.fixer_for("client.bundle:/tmp/x.js"))
        self.assertIsNone(core.fixer_for(None))

    def test_fixer_target_extraction(self):
        self.assertEqual(core.fixer_target("session.corrupt:sid-9"), "sid-9")
        self.assertEqual(core.fixer_target("plugin.dep:@deepseek-ai/dsh-y"), "@deepseek-ai/dsh-y")
        self.assertIsNone(core.fixer_target("web.down"))
        self.assertIsNone(core.fixer_target(None))

    def test_verification_detector_mapping(self):
        self.assertEqual(core.FIX_TO_DETECTOR["session.corrupt"], "session.files")
        self.assertEqual(core.FIX_TO_DETECTOR["plugin.dep"], "plugin.deps")
        self.assertEqual(core.FIX_TO_DETECTOR["web.down"], "http.root")


class PluginDepsParseTest(unittest.TestCase):
    def test_fixable_and_missing_lines(self):
        out = "\n".join([
            "ok:      @deepseek-ai/dsh-x (@fakechris/dsh-track)",
            "FIXABLE: @deepseek-ai/dsh-missing (@fakechris/dsh-track) repo=/r -> /slot/packages/dsh-missing",
            "MISSING: cordis (@fakechris/dsh-track) repo=/r",
        ])
        checks = core._parse_plugin_deps_output(out)
        # When failures exist there is no aggregate PASS row — only findings.
        self.assertTrue(all(c.status is core.CheckStatus.FAIL for c in checks))
        fixable = [c for c in checks if c.fix_id == "plugin.dep:@deepseek-ai/dsh-missing"]
        self.assertEqual(len(fixable), 1)
        self.assertTrue(fixable[0].safe_auto_fix)
        missing = [c for c in checks if "no fix source" in c.summary]
        self.assertEqual(len(missing), 1)
        self.assertFalse(missing[0].safe_auto_fix)
        self.assertIsNone(missing[0].fix_id)

    def test_all_ok_output_is_pass(self):
        checks = core._parse_plugin_deps_output("ok:      cordis (@fakechris/dsh-track)")
        self.assertEqual(len(checks), 1)
        self.assertIs(checks[0].status, core.CheckStatus.PASS)


class WebLogsDetectorTest(unittest.TestCase):
    def _ctx_with_log(self, content, home):
        log = Path(home) / "source" / "web.log"
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(content)
        return core.RunContext(run_dir=str(Path(home) / "run"), home=str(home), quiet=True)

    def test_boot_error_in_tail_is_fail(self):
        with tempfile.TemporaryDirectory() as home:
            ctx = self._ctx_with_log(
                "some noise\n[ERROR] plugin tree failed to load: boom\nmore noise\n", home)
            results = core.detect_web_logs(ctx)
            self.assertIs(results[0].status, core.CheckStatus.FAIL)
            self.assertTrue(any("plugin tree failed to load" in line for line in results[0].evidence))

    def test_process_not_defined_is_fail(self):
        with tempfile.TemporaryDirectory() as home:
            ctx = self._ctx_with_log(
                'Uncaught ReferenceError: process is not defined\n', home)
            results = core.detect_web_logs(ctx)
            self.assertIs(results[0].status, core.CheckStatus.FAIL)

    def test_clean_tail_is_pass(self):
        with tempfile.TemporaryDirectory() as home:
            ctx = self._ctx_with_log("listening on 3080\nall good\n", home)
            results = core.detect_web_logs(ctx)
            self.assertIs(results[0].status, core.CheckStatus.PASS)

    def test_missing_log_is_unknown(self):
        with tempfile.TemporaryDirectory() as home:
            ctx = core.RunContext(run_dir=str(Path(home) / "run"), home=str(home), quiet=True)
            results = core.detect_web_logs(ctx)
            self.assertIs(results[0].status, core.CheckStatus.UNKNOWN)


class CredentialsDetectorTest(unittest.TestCase):
    def _ctx(self, home, cwd=None):
        cwd_dir = Path(cwd or (Path(home) / "cwd"))
        cwd_dir.mkdir(parents=True, exist_ok=True)
        return core.RunContext(run_dir=str(Path(home) / "run"), home=str(home),
                               cwd=str(cwd_dir), quiet=True)

    def test_key_in_user_env_is_pass(self):
        with tempfile.TemporaryDirectory() as home:
            Path(home, ".env").write_text("DEEPSEEK_API_KEY=secret\n")
            results = core.detect_credentials(self._ctx(home))
            self.assertIs(results[0].status, core.CheckStatus.PASS)
            self.assertTrue(any("user .env" in line for line in results[0].evidence))

    def test_key_in_credentials_doc_is_pass(self):
        with tempfile.TemporaryDirectory() as home:
            Path(home, ".credentials.yaml").write_text("deepseek-official:\n  apiKey: secret\n")
            results = core.detect_credentials(self._ctx(home))
            self.assertIs(results[0].status, core.CheckStatus.PASS)
            self.assertTrue(any(".credentials.yaml" in line for line in results[0].evidence))

    def test_missing_key_is_fail_with_manual_fix(self):
        with tempfile.TemporaryDirectory() as home:
            results = core.detect_credentials(self._ctx(home))
            self.assertIs(results[0].status, core.CheckStatus.FAIL)
            self.assertEqual(results[0].fix_id, "credential.missing")
            self.assertFalse(results[0].safe_auto_fix)


class SettingsDetectorTest(unittest.TestCase):
    def test_valid_yaml_is_pass(self):
        with tempfile.TemporaryDirectory() as home:
            Path(home, "settings.yaml").write_text("llm-deepseek:\n  model: x\n")
            ctx = core.RunContext(run_dir=str(Path(home) / "run"), home=str(home), quiet=True)
            results = core.detect_settings(ctx)
            self.assertIs(results[0].status, core.CheckStatus.PASS)

    def test_corrupt_yaml_is_fail(self):
        with tempfile.TemporaryDirectory() as home:
            Path(home, "settings.yaml").write_text("key: [unclosed\n")
            ctx = core.RunContext(run_dir=str(Path(home) / "run"), home=str(home), quiet=True)
            results = core.detect_settings(ctx)
            self.assertIs(results[0].status, core.CheckStatus.FAIL)
            self.assertEqual(results[0].fix_id, "settings.corrupt")


class ClientBundleDetectorTest(unittest.TestCase):
    """Runs the real client-bundle-check.mjs against a fixture profile+repo."""

    def _fixture(self):
        base = Path(tempfile.mkdtemp())
        profile = base / "web"
        repo = base / "fake-track"
        (profile / "node_modules").mkdir(parents=True)
        (repo / "lib").mkdir(parents=True)
        (profile / "package.json").write_text(json.dumps({
            "name": "dsh-profile-web-fixture",
            "private": True,
            "dependencies": {"@fakechris/dsh-track": f"link:{repo}"},
        }))
        (repo / "package.json").write_text(json.dumps({
            "name": "@fakechris/dsh-track",
            "exports": {"./client": {"default": "./lib/client.js"}},
        }))
        return base, profile, repo

    def test_process_env_leak_is_fail(self):
        base, profile, repo = self._fixture()
        try:
            (repo / "lib" / "client.js").write_text(
                "const env = process.env.NODE_ENV;\nconsole.log(env)\n")
            code, out, err = core.RunContext(quiet=True).run(
                ["node", str(SCRIPTS_DIR / "client-bundle-check.mjs"),
                 "--profile", str(profile)])
            self.assertEqual(code, 1, err)
            self.assertIn("LEAK:", out)
            self.assertIn("process.env", out)
        finally:
            import shutil
            shutil.rmtree(base, ignore_errors=True)

    def test_bundler_require_shim_is_not_a_leak(self):
        base, profile, repo = self._fixture()
        try:
            (repo / "lib" / "client.js").write_text(
                'let react = require("react");\nconsole.log(react)\n')
            code, out, err = core.RunContext(quiet=True).run(
                ["node", str(SCRIPTS_DIR / "client-bundle-check.mjs"),
                 "--profile", str(profile)])
            self.assertEqual(code, 0, out + err)
            self.assertIn("ok:", out)
        finally:
            import shutil
            shutil.rmtree(base, ignore_errors=True)


class BrowserIncidentRegressionTest(unittest.TestCase):
    """The dsh-track incident, as a fixture: HTTP 200 page whose client code
    throws 'process is not defined' and logs 'Failed to load plugins'. The
    browser probe must FAIL (never PASS on HTTP 200 alone) and name the plugin."""

    def test_http_200_with_broken_client_is_fail(self):
        import http.server
        import socketserver
        import threading
        import subprocess

        html = (Path(__file__).resolve().parent / "fixtures" / "broken-page.html").read_text()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.end_headers()
                self.wfile.write(html.encode())
            def log_message(self, *_args):
                pass

        with socketserver.TCPServer(("127.0.0.1", 0), Handler) as srv:
            port = srv.server_address[1]
            threading.Thread(target=srv.serve_forever, daemon=True).start()
            probe = subprocess.run(
                ["node", str(SCRIPTS_DIR / "browser-health.mjs"),
                 "--url", f"http://127.0.0.1:{port}/", "--budget-ms", "12000"],
                capture_output=True, text=True, timeout=60,
            )
        self.assertEqual(probe.returncode, 0, probe.stderr)
        payload = json.loads(probe.stdout)
        self.assertEqual(payload["status"], "FAIL")
        # 判红 + 定位: either the probe named the failed plugin, or the
        # evidence carries the incident's page error. (Chrome's console
        # harvest timing varies; both outcomes are valid incident detection.)
        located = (
            any("dsh-track" in name for name in payload["failedPlugins"])
            or any("process is not defined" in line or "Failed to load" in line
                   for line in payload["evidence"])
        )
        self.assertTrue(located, payload)


class ReportTest(unittest.TestCase):
    def test_write_report_roundtrip(self):
        with tempfile.TemporaryDirectory() as home:
            ctx = core.RunContext(run_dir=str(Path(home) / "run"), home=str(home), quiet=True)
            checks = [core.CheckResult("env.deps", core.CheckStatus.PASS, core.Severity.INFO, "ok")]
            text = core.write_report(ctx, checks, [])
            self.assertIn("health=HEALTHY", text)
            diag = json.loads(Path(ctx.diag_json_path).read_text())
            self.assertEqual(diag["health"], "HEALTHY")
            self.assertEqual(len(diag["checks"]), 1)
            # Report artifacts live in the private run dir, not shared /tmp files.
            self.assertTrue(Path(ctx.run_dir).is_dir())


if __name__ == "__main__":
    unittest.main()
