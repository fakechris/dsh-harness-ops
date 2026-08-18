#!/usr/bin/env python3
"""
doctor_agent.py — persistent automation Agent client over `dsh --profile
automation` (PR 1 transport).

Speaks the newline-delimited JSON-RPC protocol of the SDK runtime directly
(stdlib only): initialize / session/prompt / session/cancel / shutdown, plus
the session.event / session.status / subagent.* notifications. The automation
profile keeps ONE process and its sessions alive across turns, so this client
is the transport the conversation controller (PR 3) drives: prompt → observe →
cancel a running turn → prompt again on the SAME session.

Out-of-band by design: no @deepseek-ai imports; the process it spawns is the
installed `dsh` binary running the automation profile.
"""

from __future__ import annotations

import json
import os
import queue
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import doctor_core as core  # noqa: E402


class TransportClosedError(Exception):
    """The automation process is gone or its stdio closed."""


class SdkProtocolError(Exception):
    """The runtime answered outside the documented protocol."""


@dataclass
class Notification:
    """One server→client notification: method + params (verbatim dict)."""

    method: str
    params: dict[str, object]


@dataclass
class CancelResult:
    """Outcome of session/cancel: whether the session existed and was running."""

    found: bool
    wasRunning: bool


class PersistentAgentClient:
    """One long-running `dsh --profile automation` subprocess.

    The process starts on construction, performs the initialize handshake on
    first use, and stays owned until close(). A reader thread fans
    notifications out to subscribers. Sessions survive across prompts and
    cancels inside the same process.
    """

    def __init__(
        self,
        ctx: core.RunContext,
        *,
        session_id: str,
        cwd: str,
        provider: str | None = None,
        model: str | None = None,
        dsh: str | None = None,
        argv: list[str] | None = None,
        env: dict[str, str] | None = None,
        spawn_timeout: float = 30.0,
    ) -> None:
        self.ctx = ctx
        self.session_id = session_id
        self.cwd = cwd
        self.provider = provider
        self.model = model
        self.spawn_timeout = spawn_timeout
        self._dsh = dsh or os.path.join(ctx.resolve_slot() or "", "bin", "dsh")
        if not os.path.isfile(self._dsh):
            self._dsh = "dsh"
        # Test seams: argv overrides the whole command line (a scripted fake
        # runtime); provider/model may be absent so the automation profile's
        # agentDefaultModel decides (PR 1 fallback).
        self._argv = argv
        self._env = dict(env or ctx.env)
        self._proc: subprocess.Popen[str] | None = None
        self._reader: threading.Thread | None = None
        self._pending: dict[str, queue.Queue[object]] = {}
        self._lock = threading.Lock()
        self._subscribers: dict[str, queue.Queue[Notification]] = {}
        self._subscription_serial = 0
        self._closed = False
        self._transport_error: TransportClosedError | None = None

    # -- lifecycle ------------------------------------------------------------

    def start(self) -> None:
        if self._proc is not None:
            return
        if self._closed:
            raise TransportClosedError("automation client is closed")
        try:
            self._proc = subprocess.Popen(
                self._argv or [self._dsh, "--profile", "automation"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, env=self._env, cwd=self.cwd,
            )
        except OSError as error:
            raise TransportClosedError(f"failed to spawn automation profile: {error}") from error
        self._reader = threading.Thread(target=self._read_loop, daemon=True, name="doctor-agent-reader")
        self._reader.start()

    def initialize(self) -> dict[str, object]:
        """Handshake; explicit provider/model win, otherwise the profile's
        agentDefaultModel applies (PR 1 fallback)."""
        self.start()
        params: dict[str, object] = {"cwd": self.cwd}
        if self.provider is not None:
            params["provider"] = self.provider
        if self.model is not None:
            params["model"] = self.model
        result = self._request("initialize", params)
        if not isinstance(result, dict) or not isinstance(result.get("serverInfo"), dict):
            raise SdkProtocolError(f"initialize returned no server identity: {result!r}")
        return result

    def prompt(self, content_blocks: list[dict[str, object]]) -> str:
        """Queue one user turn on this client's session; returns the message id."""
        result = self._request("session/prompt", {
            "sessionId": self.session_id,
            "contentBlocks": content_blocks,
        })
        if not isinstance(result, dict) or not isinstance(result.get("messageId"), str):
            raise SdkProtocolError(f"session/prompt returned no message id: {result!r}")
        return result["messageId"]

    def cancel(self) -> CancelResult:
        """Abort the running turn (if any) and settle; the session survives."""
        result = self._request("session/cancel", {"sessionId": self.session_id})
        if not isinstance(result, dict) or not isinstance(result.get("found"), bool) \
                or not isinstance(result.get("wasRunning"), bool):
            raise SdkProtocolError(f"session/cancel returned no cancel result: {result!r}")
        return CancelResult(found=result["found"], wasRunning=result["wasRunning"])

    def shutdown(self) -> None:
        """Protocol shutdown: the runtime disposes its tree and exits 0."""
        if self._proc is None:
            return
        try:
            self._request("shutdown", {}, timeout=self.spawn_timeout)
        except (TransportClosedError, SdkProtocolError):
            pass

    def close(self) -> None:
        """Best-effort shutdown, then EOF → TERM → KILL reap. Idempotent."""
        if self._closed:
            return
        self._closed = True
        self.shutdown()
        proc = self._proc
        if proc is None:
            return
        try:
            if proc.stdin is not None:
                proc.stdin.close()
        except OSError:
            pass
        try:
            proc.wait(timeout=6)
        except subprocess.TimeoutExpired:
            proc.terminate()
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
        self._fail_all(TransportClosedError("automation client closed"))

    # -- notifications --------------------------------------------------------

    def subscribe(self, filter_fn=None):
        """Yield a per-subscriber queue; caller drains it with get_nowait/block."""
        subscription_id = str(self._subscription_serial)
        self._subscription_serial += 1
        q: queue.Queue[Notification] = queue.Queue()
        with self._lock:
            if self._transport_error is not None:
                q.put(self._transport_error)
            else:
                self._subscribers[subscription_id] = q
        return q

    # -- internals ------------------------------------------------------------

    def _request(self, method: str, params: object, timeout: float | None = None) -> object:
        self.start()
        proc = self._proc
        assert proc is not None
        request_id = f"req_{uuid.uuid4().hex}"
        box: queue.Queue[object] = queue.Queue(maxsize=1)
        with self._lock:
            if self._transport_error is not None:
                raise self._transport_error
            self._pending[request_id] = box
        frame = {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        try:
            assert proc.stdin is not None
            proc.stdin.write(json.dumps(frame) + "\n")
            proc.stdin.flush()
        except (BrokenPipeError, OSError, ValueError) as error:
            with self._lock:
                self._pending.pop(request_id, None)
            raise TransportClosedError(f"automation stdin closed: {error}") from error
        try:
            item = box.get(timeout=timeout or 60)
        except queue.Empty as error:
            with self._lock:
                self._pending.pop(request_id, None)
            raise TransportClosedError(f"{method} timed out") from error
        if isinstance(item, Exception):
            raise item
        if not isinstance(item, dict):
            raise SdkProtocolError(f"{method} response was not an object: {item!r}")
        if "error" in item:
            raise SdkProtocolError(f"{method} error: {item['error']!r}")
        return item.get("result")

    def _read_loop(self) -> None:
        proc = self._proc
        assert proc is not None and proc.stdout is not None
        buffer = ""
        try:
            while True:
                chunk = proc.stdout.readline()
                if chunk == "":
                    break
                buffer += chunk
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        frame = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    self._dispatch(frame)
        except (OSError, ValueError):
            pass
        self._fail_all(TransportClosedError("automation stdout closed"))

    def _dispatch(self, frame: object) -> None:
        if not isinstance(frame, dict):
            return
        method = frame.get("method")
        if isinstance(method, str) and "id" not in frame:
            notification = Notification(method, frame.get("params") if isinstance(frame.get("params"), dict) else {})
            with self._lock:
                subscribers = list(self._subscribers.values())
            for q in subscribers:
                try:
                    q.put_nowait(notification)
                except queue.Full:
                    pass
            return
        request_id = frame.get("id")
        if isinstance(request_id, str):
            with self._lock:
                box = self._pending.pop(request_id, None)
            if box is not None:
                box.put_nowait(frame)

    def _fail_all(self, error: TransportClosedError) -> None:
        with self._lock:
            if self._transport_error is None:
                self._transport_error = error
            pending = list(self._pending.values())
            self._pending.clear()
            subscribers = list(self._subscribers.values())
            self._subscribers.clear()
        for box in pending:
            box.put_nowait(error)
        for q in subscribers:
            try:
                q.put_nowait(error)
            except queue.Full:
                pass
