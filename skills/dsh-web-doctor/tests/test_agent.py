#!/usr/bin/env python3
"""test_agent.py — PersistentAgentClient (doctor_agent.py) tests against the
scripted fake automation runtime (fake-automation.py): same-session multi-turn
memory, cancel keeps the session alive, notification streaming, clean close."""

from __future__ import annotations

import json
import os
import queue
import sys
import tempfile
import time
import unittest
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = TESTS_DIR.parent / "scripts"
sys.path.insert(0, str(SCRIPTS_DIR))

import doctor_agent as agent  # noqa: E402
import doctor_core as core  # noqa: E402

FAKE_RUNTIME = str(TESTS_DIR / "fake-automation.py")


def make_client(tmp: str, extra_env: dict[str, str] | None = None) -> agent.PersistentAgentClient:
    ctx = core.RunContext(run_dir=str(Path(tmp) / "run"), quiet=True)
    env = dict(os.environ)
    env.update(extra_env or {})
    return agent.PersistentAgentClient(
        ctx, session_id="session-1", cwd=tmp,
        dsh=sys.executable, argv=[sys.executable, FAKE_RUNTIME], env=env,
    )


class AgentTransportTest(unittest.TestCase):
    def test_same_session_multi_turn_memory(self):
        with tempfile.TemporaryDirectory() as tmp:
            memory = str(Path(tmp) / "memory.jsonl")
            client = make_client(tmp, {"FAKE_MEMORY": memory})
            try:
                init = client.initialize()
                self.assertEqual(init["serverInfo"]["name"], "fake-automation")
                self.assertIsInstance(client.prompt([{"type": "text", "text": "remember 42"}]), str)
                self.assertIsInstance(client.prompt([{"type": "text", "text": "what number?"}]), str)
                client.shutdown()
                received = [json.loads(line) for line in open(memory)]
                # Both prompts reached the SAME session/process (one memory file).
                self.assertEqual(len(received), 2)
                self.assertEqual(received[0][0]["text"], "remember 42")
            finally:
                client.close()

    def test_cancel_keeps_session_alive(self):
        with tempfile.TemporaryDirectory() as tmp:
            client = make_client(tmp)
            try:
                client.initialize()
                result = client.cancel()
                self.assertTrue(result.found)
                # Idle cancel is a no-op; the session stays usable.
                self.assertIsInstance(client.prompt([{"type": "text", "text": "after cancel"}]), str)
                client.shutdown()
            finally:
                client.close()

    def test_notifications_stream(self):
        with tempfile.TemporaryDirectory() as tmp:
            client = make_client(tmp)
            try:
                client.initialize()
                q = client.subscribe()
                client.prompt([{"type": "text", "text": "stream"}])
                methods: list[str] = []
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline and len(methods) < 3:
                    try:
                        item = q.get(timeout=0.2)
                    except queue.Empty:
                        continue
                    if isinstance(item, agent.Notification):
                        methods.append(item.method)
                    elif isinstance(item, Exception):
                        raise item
                self.assertIn("session.status", methods)
                self.assertIn("session.event", methods)
                client.shutdown()
            finally:
                client.close()

    def test_close_is_idempotent_and_reaps(self):
        with tempfile.TemporaryDirectory() as tmp:
            client = make_client(tmp)
            try:
                client.initialize()
                client.close()
                client.close()  # must not raise
                self.assertEqual(client._proc.returncode, 0)  # process reaped
            finally:
                client.close()

    def test_transport_error_surfaces_on_request(self):
        with tempfile.TemporaryDirectory() as tmp:
            ctx = core.RunContext(run_dir=str(Path(tmp) / "run"), quiet=True)
            client = agent.PersistentAgentClient(
                ctx, session_id="x", cwd=tmp,
                dsh="/nonexistent/dsh-binary", argv=["/nonexistent/dsh-binary"], env=dict(os.environ),
            )
            with self.assertRaises(agent.TransportClosedError):
                client.initialize()
            client.close()


if __name__ == "__main__":
    unittest.main()
