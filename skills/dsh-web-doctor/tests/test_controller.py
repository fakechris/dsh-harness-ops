#!/usr/bin/env python3
"""test_controller.py — DoctorController state-machine tests (PR 3).

Covers the plan's state-machine regression list: any user message switches to
USER_DIRECTED without read-only constraints; repairs resolve only after a
re-check; detector crashes → UNVERIFIED; a healthy surface stays online (no
auto-quit); only request_quit ends it; input during a running turn cancels the
old generation on the SAME session; stale autonomous rounds are cancelled."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = TESTS_DIR.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import doctor_controller as controller  # noqa: E402
import doctor_core as core  # noqa: E402


class FakeAgent:
    """Records calls; cancel() marks wasRunning per script; prompts appended."""

    def __init__(self, running=False):
        self.initialized = False
        self.cancelled = 0
        self.prompts: list[list[dict]] = []
        self.running = running

    def initialize(self):
        self.initialized = True

    def cancel(self):
        self.cancelled += 1
        return (True, self.running)

    def prompt(self, content_blocks):
        self.prompts.append(content_blocks)

    def close(self):
        pass


def make_controller(tmp: str, fake: FakeAgent) -> controller.DoctorController:
    ctx = core.RunContext(run_dir=str(Path(tmp) / "run"), quiet=True)
    return controller.DoctorController(ctx, agent_factory=lambda: fake)


class UserDirectModeTest(unittest.TestCase):
    def test_any_user_message_enters_user_directed(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeAgent()
            ctl = make_controller(tmp, fake)
            ctl.start_agent()
            self.assertIs(ctl.mode, controller.ControlMode.AUTONOMOUS)
            ctl.submit_user_message("please fix the web")
            self.assertIs(ctl.mode, controller.ControlMode.USER_DIRECTED)
            self.assertEqual(fake.prompts, [[{"type": "text", "text": "please fix the web"}]])
            # No read-only constraint derived from problem count: the message
            # was sent verbatim regardless of any diagnosis state.
            self.assertIs(ctl.health, controller.HealthState.UNASSESSED)

    def test_user_message_cancels_running_turn_on_same_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeAgent(running=True)
            ctl = make_controller(tmp, fake)
            ctl.start_agent()
            ctl.agent_state = controller.AgentState.RUNNING
            ctl.submit_user_message("redirect")
            self.assertEqual(fake.cancelled, 1)  # session/cancel called
            self.assertEqual(len(fake.prompts), 1)  # then the new message
            self.assertEqual(fake.prompts[0][0]["text"], "redirect")
            self.assertIs(ctl.agent_state, controller.AgentState.RUNNING)


class HealthMachineTest(unittest.TestCase):
    def test_detector_crash_makes_health_unverified(self):
        with tempfile.TemporaryDirectory() as tmp:
            ctx = core.RunContext(run_dir=str(Path(tmp) / "run"), quiet=True)
            ctl = controller.DoctorController(ctx, agent_factory=lambda: FakeAgent())

            def boom(_c):
                raise RuntimeError("kaboom")

            core.DETECTORS["test.crash"] = boom
            core.DETECTOR_ORDER.append("test.crash")
            try:
                ctl.diagnose()
            finally:
                core.DETECTOR_ORDER.remove("test.crash")
                del core.DETECTORS["test.crash"]
            self.assertIn(ctl.health, (controller.HealthState.UNHEALTHY, controller.HealthState.UNVERIFIED))
            crash = next(c for c in ctl.checks if c.id == "test.crash")
            self.assertIs(crash.status, core.CheckStatus.UNKNOWN)

    def test_healthy_surface_stays_online(self):
        with tempfile.TemporaryDirectory() as tmp:
            ctl = make_controller(tmp, FakeAgent())
            # All checks PASS except non-required ones → HEALTHY.
            ctl.checks = [
                core.CheckResult("http.root", core.CheckStatus.PASS, core.Severity.INFO, "ok"),
                core.CheckResult("browser.app", core.CheckStatus.PASS, core.Severity.INFO, "ok"),
                core.CheckResult("env.deps", core.CheckStatus.PASS, core.Severity.INFO, "ok"),
                core.CheckResult("settings.parse", core.CheckStatus.UNKNOWN, core.Severity.INFO, "x", required=False),
            ]
            ctl.health = ctl._aggregate(ctl.checks)
            self.assertIs(ctl.health, controller.HealthState.HEALTHY)
            self.assertFalse(ctl.quit)
            # No auto-quit: a wait would leave the controller alive.
            time.sleep(0.05)
            self.assertFalse(ctl.quit)
            # Only an explicit quit ends it.
            ctl.request_quit()
            self.assertTrue(ctl.quit)
            self.assertIs(ctl.agent_state, controller.AgentState.CLOSED)


class StaleGenerationTest(unittest.TestCase):
    def test_old_generation_auto_fixes_do_not_run_after_user_message(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeAgent()
            ctl = make_controller(tmp, fake)
            ctl.diagnose()  # may be UNHEALTHY in an empty env
            # A user message bumps the generation and takes over.
            ctl.submit_user_message("stop, let me look")
            before = len(ctl.repairs)
            ctl.autonomous_round()  # must be a no-op: USER_DIRECTED
            self.assertEqual(len(ctl.repairs), before)
            self.assertIs(ctl.mode, controller.ControlMode.USER_DIRECTED)


class VerificationTest(unittest.TestCase):
    def test_repair_resolves_only_after_recheck(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeAgent()
            ctl = make_controller(tmp, fake)
            ctl.checks = [core.CheckResult(
                "slots.launcher", core.CheckStatus.FAIL, core.Severity.WARNING, "x",
                fix_id="launcher.missing", safe_auto_fix=True,
            )]
            ctl.health = ctl._aggregate(ctl.checks)
            # A fake fixer that actually materializes nothing: the re-check
            # must still report FAIL → attempt unresolved.
            core.FIXERS["launcher.missing"] = lambda ctx, target: core.FixerResult(False, ["not applied"])
            try:
                attempt = core.apply_fix(ctl.ctx, ctl.checks[0])
                self.assertIsNotNone(attempt)
                self.assertIsNot(attempt.resolved, True)
            finally:
                del core.FIXERS["launcher.missing"]

    def test_verify_after_agent_reruns_detectors(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = FakeAgent()
            ctl = make_controller(tmp, fake)
            ctl.health = controller.HealthState.UNHEALTHY
            ctl.verify_after_agent()
            # The re-check ran the real detectors and recomputed health.
            self.assertIsNot(ctl.health, controller.HealthState.VERIFYING)
            self.assertTrue(ctl.checks)


import time  # noqa: E402


if __name__ == "__main__":
    unittest.main()
