#!/usr/bin/env python3
"""Fake automation runtime for doctor_agent tests: speaks the SDK JSON-RPC
protocol on stdio. Scripted via env vars:
  FAKE_PROMPT_TEXT    assistant text per turn (default "fake reply")
  FAKE_HANG_PROMPT    never answer session/prompt (running-turn cancel test)
  FAKE_SESSION_ID     remembered session id (default "session-1")
  FAKE_MEMORY         write received prompts to this file, one JSON per line
Behavior: initialize → serverInfo; session/prompt → stream session.event +
session.status (running/idle) + respond messageId (unless FAKE_HANG_PROMPT);
session/cancel → respond {found, wasRunning}; shutdown → respond {} and exit 0.
"""

import json
import os
import sys

FAKE_TEXT = os.environ.get("FAKE_PROMPT_TEXT", "fake reply")
HANG = "FAKE_HANG_PROMPT" in os.environ
MEMORY = os.environ.get("FAKE_MEMORY")
SESSION_ID = os.environ.get("FAKE_SESSION_ID", "session-1")

seq = 0


def write(frame):
    sys.stdout.write(json.dumps(frame) + "\n")
    sys.stdout.flush()


def notify(method, params):
    write({"jsonrpc": "2.0", "method": method, "params": params})


def event(event_type, data):
    global seq
    notify("session.event", {"sessionId": SESSION_ID, "event": {"type": event_type, "seq": seq, "time": 0, "data": data}})
    seq += 1


def run_turn(message_id):
    event("agent/inbox/spliced", {"target": "next-turn", "start": 0, "inserted": [{"id": message_id}]})
    notify("session.status", {"sessionId": SESSION_ID, "status": "running"})
    event("assistant/message", {"message": {"role": "assistant", "content": [{"type": "text", "text": FAKE_TEXT}]}})
    event("turn/end", {"turn": 1, "reason": {"kind": "completed"}})
    notify("session.status", {"sessionId": SESSION_ID, "status": "idle"})


for line in sys.stdin:
    try:
        msg = json.loads(line)
    except json.JSONDecodeError:
        continue
    method = msg.get("method")
    rid = msg.get("id")
    if method == "initialize":
        write({"jsonrpc": "2.0", "id": rid, "result": {"serverInfo": {"name": "fake-automation", "version": "0.0.1"}}})
    elif method == "session/prompt":
        params = msg.get("params") or {}
        if MEMORY:
            with open(MEMORY, "a") as fh:
                fh.write(json.dumps(params.get("contentBlocks")) + "\n")
        if HANG:
            continue  # never answer — the turn stays running
        message_id = f"msg-{seq}"
        run_turn(message_id)
        write({"jsonrpc": "2.0", "id": rid, "result": {"messageId": message_id}})
    elif method == "session/cancel":
        write({"jsonrpc": "2.0", "id": rid, "result": {"found": True, "wasRunning": not HANG or True}})
    elif method == "shutdown":
        write({"jsonrpc": "2.0", "id": rid, "result": {}})
        break
