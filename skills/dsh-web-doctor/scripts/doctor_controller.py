#!/usr/bin/env python3
"""
doctor_controller.py — conversation/workflow state machine (PR 3).

Two orthogonal state sets, per the redesign:

  health:  UNASSESSED → CHECKING → { HEALTHY | UNVERIFIED | UNHEALTHY } → VERIFYING
  agent:   STARTING → IDLE → RUNNING → CANCELLING → (IDLE | FAILED) ; CLOSED terminal

Repair outcomes are recorded as RepairAttempts (doctor_core) — never as
conversation-terminal states. HEALTHY is not a terminal state: the surface
stays online until an explicit quit.

Event priority:
  1. /quit, EOF, terminal close
  2. the user's latest message — cancels the previous generation's pending
     automatic actions, cancels a running agent turn via session/cancel,
     waits for the SAME session to settle, then sends the message verbatim
  3. safety / authorization limits
  4. forced verification after any repair (re-run the associated detector)
  5. precise deterministic fixes (safe fixers only, only their own findings)
  6. default autonomous diagnosis

There is no keyword classifier: ANY user message switches control to
USER_DIRECTED and the agent decides what to do with the verbatim text.
Deterministic results are context for the agent, never hard constraints
(no "0 problems so you may not modify anything").
"""

from __future__ import annotations

import enum
import os
import sys
import threading
import time
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import doctor_core as core  # noqa: E402


class HealthState(str, enum.Enum):
    UNASSESSED = "UNASSESSED"
    CHECKING = "CHECKING"
    HEALTHY = "HEALTHY"
    UNVERIFIED = "UNVERIFIED"
    UNHEALTHY = "UNHEALTHY"
    VERIFYING = "VERIFYING"


class AgentState(str, enum.Enum):
    STARTING = "STARTING"
    IDLE = "IDLE"
    RUNNING = "RUNNING"
    CANCELLING = "CANCELLING"
    FAILED = "FAILED"
    CLOSED = "CLOSED"


class ControlMode(str, enum.Enum):
    """Who currently owns the conversation. Any user message → USER_DIRECTED."""

    AUTONOMOUS = "AUTONOMOUS"  # no user instruction yet; default auto flow
    USER_DIRECTED = "USER_DIRECTED"  # the user's latest message is the task


@dataclass
class ControllerEvent:
    """One observable controller transition for a renderer/subscriber."""

    kind: str  # 'health', 'agent', 'mode', 'repair', 'message', 'quit'
    detail: object = None
    at: float = field(default_factory=time.time)


class DoctorController:
    """Thread-safe conversation controller over one persistent automation
    session. Subscribers receive ControllerEvents; the renderer (PR 4) owns
    presentation, never blocking logic."""

    def __init__(
        self,
        ctx: core.RunContext,
        *,
        agent_session_id: str = "doctor",
        agent_factory=None,
    ) -> None:
        self.ctx = ctx
        self.agent_session_id = agent_session_id
        self._agent_factory = agent_factory or (lambda: self._default_agent())
        self._agent = None
        self._lock = threading.RLock()
        self._subscribers: list = []
        self.health = HealthState.UNASSESSED
        self.agent_state = AgentState.CLOSED
        self.mode = ControlMode.AUTONOMOUS
        self.instruction_generation = 0  # bumped by every user message
        self._last_instruction: str | None = None
        self.checks: list[core.CheckResult] = []
        self.repairs: list[core.RepairAttempt] = []
        self.quit = False
        self._quit_reason: str | None = None

    # -- subscription ---------------------------------------------------------

    def subscribe(self, handler) -> None:
        """handler(event: ControllerEvent) — called under the lock; keep it cheap."""
        with self._lock:
            self._subscribers.append(handler)

    def _emit(self, kind: str, detail: object = None) -> None:
        event = ControllerEvent(kind, detail)
        for handler in list(self._subscribers):
            try:
                handler(event)
            except Exception:  # noqa: BLE001 — a bad subscriber never breaks the controller
                pass

    # -- agent lifecycle ------------------------------------------------------

    def _default_agent(self):
        from . import doctor_agent as agent  # noqa: E402
        return agent.PersistentAgentClient(
            self.ctx, session_id=self.agent_session_id, cwd=self.ctx.cwd,
        )

    def start_agent(self) -> None:
        with self._lock:
            if self._agent is not None:
                return
            self._set_agent(AgentState.STARTING)
            try:
                self._agent = self._agent_factory()
                self._agent.initialize()
                self._set_agent(AgentState.IDLE)
            except Exception as error:  # noqa: BLE001
                self._set_agent(AgentState.FAILED, detail=str(error))
                self._agent = None
                raise

    def _set_agent(self, state: AgentState, detail: object = None) -> None:
        self.agent_state = state
        self._emit("agent", {"state": state.value, "detail": detail})

    # -- health ---------------------------------------------------------------

    def diagnose(self) -> None:
        with self._lock:
            self.health = HealthState.CHECKING
            self._emit("health", {"state": self.health.value})
            self.checks = core.run_all_detectors(self.ctx)
            self.health = self._aggregate(self.checks)
            self._emit("health", {
                "state": self.health.value,
                "counts": {s.value: sum(1 for c in self.checks if c.status is s) for s in core.CheckStatus},
            })

    @staticmethod
    def _aggregate(checks: list[core.CheckResult]) -> HealthState:
        return {
            core.Health.HEALTHY: HealthState.HEALTHY,
            core.Health.UNHEALTHY: HealthState.UNHEALTHY,
            core.Health.UNVERIFIED: HealthState.UNVERIFIED,
        }[core.aggregate_health(checks)]

    # -- user input (priority 2) ----------------------------------------------

    def submit_user_message(self, text: str) -> None:
        """The user's latest message: cancel the old generation's pending
        automatic actions, cancel a running turn on the SAME session, wait for
        it to settle, then send the message verbatim."""
        with self._lock:
            if self.quit:
                return
            self.instruction_generation += 1
            self.mode = ControlMode.USER_DIRECTED
            self._last_instruction = text
            self._emit("mode", {"mode": self.mode.value})
            self._emit("message", {"generation": self.instruction_generation, "text": text})
            if self._agent is None:
                self.start_agent()
            if self._agent is None:
                return
            if self.agent_state is AgentState.RUNNING:
                self._set_agent(AgentState.CANCELLING)
                try:
                    self._agent.cancel()  # same session survives
                except Exception as error:  # noqa: BLE001
                    self._set_agent(AgentState.FAILED, detail=str(error))
                    return
            self._set_agent(AgentState.RUNNING)
            try:
                self._agent.prompt([{"type": "text", "text": text}])
            except Exception as error:  # noqa: BLE001
                self._set_agent(AgentState.FAILED, detail=str(error))

    def on_agent_idle(self) -> None:
        """The renderer/agent event loop reports the agent reached idle."""
        with self._lock:
            if self.agent_state in (AgentState.RUNNING, AgentState.CANCELLING):
                self._set_agent(AgentState.IDLE)

    # -- autonomous flow (priority 6, gated by 3/4/5) -------------------------

    def autonomous_round(self) -> None:
        """One default-autonomy step: only when no user instruction is pending
        (generation unchanged). Deterministic safe fixes first, then let the
        agent investigate leftovers; every repair is verified by re-checking."""
        with self._lock:
            if self.quit or self.mode is ControlMode.USER_DIRECTED:
                return
            generation = self.instruction_generation
            if self.health is HealthState.UNASSESSED:
                self.diagnose()
            if self.health is HealthState.HEALTHY:
                # Evidence already collected; the surface stays online.
                self._emit("health", {"state": self.health.value, "healthy_evidence": True})
                return
            if self.health is HealthState.UNHEALTHY:
                self._run_safe_fixes(generation)
            if self.quit or self.mode is ControlMode.USER_DIRECTED:
                return
            if self.health in (HealthState.UNVERIFIED, HealthState.UNHEALTHY):
                self._delegate_to_agent(generation)

    def _run_safe_fixes(self, generation: int) -> None:
        """Priority 5: precise safe fixers only. A generation bump (a user
        message) cancels this round before any fixer runs."""
        self._emit("health", {"state": HealthState.VERIFYING.value, "phase": "fixes"})
        for check in self.checks:
            if self._stale(generation):
                return
            if check.status is not core.CheckStatus.FAIL or not check.safe_auto_fix or check.fix_id is None:
                continue
            if check.fix_id == "web.down":
                continue  # relaunch stays opt-in (--restart)
            attempt = core.apply_fix(self.ctx, check)
            if attempt is not None:
                self.repairs.append(attempt)
                self._emit("repair", {"fix_id": attempt.fix_id, "resolved": attempt.resolved})
        # Refresh the full diagnosis so the report reflects the post-fix state.
        self.checks = core.run_all_detectors(self.ctx)
        self.health = self._aggregate(self.checks)

    def _delegate_to_agent(self, generation: int) -> None:
        """Priority 6 tail: the agent investigates remaining findings on the
        persistent session. The prompt embeds the deterministic evidence as
        context — never as hard constraints."""
        if self._stale(generation):
            return
        self.start_agent()
        if self._agent is None:
            return
        evidence = core.write_report(self.ctx, self.checks, self.repairs)
        prompt = (
            "以下是 dsh-web-doctor 的确定性体检证据（只读）。请调查并修复剩余问题，"
            "每步验证；只有需要用户决策时才停下提问。修复后重新执行 dsh-doctor "
            "--diag-json 确认。\n\n" + evidence
        )
        self._set_agent(AgentState.RUNNING)
        try:
            self._agent.prompt([{"type": "text", "text": prompt}])
        except Exception as error:  # noqa: BLE001
            self._set_agent(AgentState.FAILED, detail=str(error))

    def verify_after_agent(self) -> None:
        """Priority 4: after any agent repair, findings resolve ONLY when the
        re-check passes — never by the agent's own claim."""
        with self._lock:
            self.health = HealthState.VERIFYING
            self._emit("health", {"state": self.health.value, "phase": "verify"})
            self.checks = core.run_all_detectors(self.ctx)
            self.health = self._aggregate(self.checks)
            self._emit("health", {"state": self.health.value, "verified": True})

    def _stale(self, generation: int) -> bool:
        return self.instruction_generation != generation or self.quit

    # -- quit (priority 1) ----------------------------------------------------

    def request_quit(self, reason: str = "user") -> None:
        with self._lock:
            if self.quit:
                return
            self.quit = True
            self._quit_reason = reason
            self._emit("quit", {"reason": reason})
            agent = self._agent
        if agent is not None:
            try:
                agent.close()
            except Exception:  # noqa: BLE001
                pass
        with self._lock:
            self._set_agent(AgentState.CLOSED)
