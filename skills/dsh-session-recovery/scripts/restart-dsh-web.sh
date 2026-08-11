#!/bin/sh
# restart-dsh-web.sh — gracefully restart `dsh web` and wait until it serves.
#
# WHY: the workspace registry builds its session index only at startup. After
# repairing session logs you MUST restart the server, or the GUI keeps showing
# "0 sessions". The new server is nohup'd so it survives this script (and any
# agent process) exiting.
#
# Usage:
#   sh restart-dsh-web.sh [old-pid] [port] [start-dir]
# Defaults: old-pid = current listener on the port; port = 3080;
#           start-dir = cwd of the old listener (falls back to $HOME).
set -u

PORT="${2:-3080}"
LOG=/tmp/dsh-web-restart.log

# Detect the old listener (and its cwd) unless a pid was given.
OLD_PID="${1:-}"
if [ -z "$OLD_PID" ]; then
  OLD_PID=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | head -1)
fi
START_DIR="${3:-}"
if [ -z "$START_DIR" ] && [ -n "$OLD_PID" ]; then
  START_DIR=$(lsof -a -p "$OLD_PID" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
fi
START_DIR="${START_DIR:-$HOME}"
echo "[$(date +%H:%M:%S)] old pid=${OLD_PID:-none} port=$PORT start-dir=$START_DIR"

if [ -n "$OLD_PID" ]; then
  echo "[$(date +%H:%M:%S)] sending SIGTERM to $OLD_PID"
  kill -TERM "$OLD_PID" 2>/dev/null || true
  waited=0
  while [ "$waited" -lt 45 ]; do
    if ! lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then break; fi
    waited=$((waited + 1)); sleep 1
  done
  if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[$(date +%H:%M:%S)] did not exit after ${waited}s, sending SIGKILL"
    kill -9 "$OLD_PID" 2>/dev/null || true
    sleep 2
  fi
fi

echo "[$(date +%H:%M:%S)] starting dsh web from $START_DIR"
cd "$START_DIR" || { echo "cd $START_DIR failed"; exit 1; }
nohup dsh web > "$LOG" 2>&1 &
NEW_PID=$!
echo "[$(date +%H:%M:%S)] new server pid $NEW_PID (log: $LOG)"

for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then
    echo "[$(date +%H:%M:%S)] UP after ${i}s (HTTP $code)"
    exit 0
  fi
  sleep 1
done
echo "[$(date +%H:%M:%S)] SERVER NOT UP after 120s"
tail -80 "$LOG"
exit 1
