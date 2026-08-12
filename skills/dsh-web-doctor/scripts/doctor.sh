#!/usr/bin/env bash
# dsh-web-doctor — OUT-OF-BAND diagnosis, repair and relaunch for dsh web.
#
# Use this when the web (3080) is down or won't boot — including when BOTH A/B
# slots are broken — and the normal GUI/agent path is unavailable. It runs
# entirely from the terminal with local tools (node/zstd/jq/curl/ps/lsof) and
# the installed skills' scripts; it does NOT depend on a running web process.
#
# What it does, in order:
#   1. environment + layout snapshot (current slot, ab-state, web, launcher)
#   2. diagnosis: web health, launcher chain, extension relinks, slot bootable,
#      session store health, web.log tail, and "what happened last" in the most
#      recently active sessions
#   3. --fix: apply known self-heals (relink recreate, slot launcher, unknown
#      session-event ignorable marking, corrupt-log repair)
#   4. --restart: relaunch dsh web and poll HTTP 200
#   5. report: what was found, what was fixed, what still needs a human
#
# Usage:
#   doctor.sh                 # diagnose only (read-only)
#   doctor.sh --fix           # diagnose + auto-fix known issues
#   doctor.sh --fix --restart # diagnose + fix + relaunch web
#   doctor.sh --quiet         # less chatter
#
# Exit codes: 0 all-clear (or fixed+up); 1 diagnosis found problems;
# 2 web not up after restart. Safe to re-run; every fix is reversible and
# backed up by the underlying scripts.
set -uo pipefail

SKILLS_DIR="${DSH_SKILLS_DIR:-$HOME/.dsh/skills}"
DSH_SOURCE="${DSH_SOURCE:-$HOME/.dsh/source}"
AB="$SKILLS_DIR/dsh-snapshot-ab/scripts/ab.sh"
REC="$SKILLS_DIR/dsh-session-recovery/scripts"
PORT="${DSH_WEB_PORT:-3080}"

FLAG_FIX=0; FLAG_RESTART=0; FLAG_QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fix) FLAG_FIX=1; shift ;;
    --restart) FLAG_RESTART=1; shift ;;
    --quiet) FLAG_QUIET=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

say()  { [ "$FLAG_QUIET" = "1" ] || printf '%s\n' "$*"; }
warn() { printf '\033[1;33m[doctor]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[doctor]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[doctor]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[doctor]\033[0m %s\n' "$*"; }

PROBLEMS=0
note_problem() { PROBLEMS=$((PROBLEMS + 1)); }

# --- 1. environment ----------------------------------------------------------
info "dsh-web-doctor (out-of-band) — port $PORT"
missing=""
for t in node zstd jq curl ps lsof; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
  err "missing required tools:$missing — doctor cannot run"
  exit 2
fi

# --- 2. layout snapshot ------------------------------------------------------
CURRENT="<none>"
[ -L "$DSH_SOURCE/current" ] && CURRENT=$(readlink "$DSH_SOURCE/current")
info "current: $CURRENT"
if [ -f "$DSH_SOURCE/ab-state.json" ]; then
  python3 - "$DSH_SOURCE/ab-state.json" <<'PY' | while IFS= read -r line; do say "$line"; done
import json, sys
d = json.load(open(sys.argv[1]))
print(f"  phase={d.get('phase')} current-slot={d.get('current')} confirmed={d.get('confirmed')}")
PY
fi
[ -n "$CURRENT" ] || { err "no current symlink — the A/B layout is missing"; note_problem; }

# --- 3. diagnosis ------------------------------------------------------------
echo
info "== diagnosis =="

# 3a. web health
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
if [ "$code" = "200" ]; then
  ok "web on :$PORT answers HTTP 200"
else
  err "web on :$PORT answers HTTP $code (not up)"
  note_problem
fi

# 3b. launcher chain
launcher=$(command -v dsh || true)
if [ -n "$launcher" ]; then
  resolved=$(readlink "$launcher" 2>/dev/null || echo "$launcher")
  say "  launcher: $launcher -> $resolved"
  # `current` is a symlink; readlink does not recurse, so accept both the
  # real slot path and the `$DSH_SOURCE/current/...` spelling (which resolves
  # to the current slot at exec time).
  if [ -n "$CURRENT" ] && [[ "$resolved" != "$CURRENT/"* ]] && [[ "$resolved" != "$DSH_SOURCE/current/"* ]]; then
    warn "launcher resolves outside current slot ($resolved)"
  fi
  if [ -f "$launcher" ] && [ ! -x "$launcher" ]; then
    err "launcher exists but is not executable: $launcher"
    note_problem
  fi
else
  err "'dsh' not on PATH — launcher chain broken"
  note_problem
fi

# 3c. extension relinks (against current)
if [ -f "$DSH_SOURCE/ab-config.json" ]; then
  echo
  say "== extension relinks =="
  python3 - "$DSH_SOURCE/ab-config.json" "$CURRENT" <<'PY' | while IFS= read -r line; do case "$line" in MISSING:*) err "${line#MISSING:}"; note_problem;; *) say "  $line";; esac; done
import json, os, sys
cfg, cur = sys.argv[1], sys.argv[2]
d = json.load(open(cfg))
for ext in d.get('extensions', []):
    repo = ext.get('repo', '')
    for link, rel in (ext.get('relink') or {}).items():
        target = f"{repo}/{link}"
        if not os.path.exists(target):
            print(f"MISSING: relink {target} (needs -> {cur}/{rel})")
        else:
            print(f"ok: {link} -> {rel}")
PY
fi

# 3d. slot bootable
if [ -n "$CURRENT" ]; then
  echo
  say "== current slot bootability =="
  if [ -x "$CURRENT/bin/dsh" ]; then
    say "  bin/dsh present"
  elif [ -x "$CURRENT/apps/cli/lib/bin.js" ]; then
    warn "  no bin/dsh — compiled CLI present (launcher chain may still break if bin/dsh is what ~/.local/bin/dsh resolves to)"
    note_problem
  else
    err "  current slot has neither bin/dsh nor apps/cli/lib/bin.js — not bootable"
    note_problem
  fi
fi

# 3e. session store health (lightweight: check-all-sessions)
echo
say "== session store =="
if [ -f "$REC/check-all-sessions.mjs" ]; then
  out=$(node "$REC/check-all-sessions.mjs" 2>&1)
  rc=$?
  tail_line=$(printf '%s\n' "$out" | tail -1)
  if [ "$rc" = "0" ]; then
    ok "sessions: $tail_line"
  else
    err "sessions: $tail_line"
    note_problem
  fi
else
  err "check-all-sessions.mjs missing — session store not checked"
  note_problem
fi

# 3f. web.log tail
if [ -f "$DSH_SOURCE/web.log" ]; then
  echo
  say "== web.log tail =="
  tail -8 "$DSH_SOURCE/web.log" | sed 's/^/  /' >&2
fi

# 3g. what happened last (most recently active sessions)
echo
say "== last activity in recent sessions =="
if [ -f "$SKILLS_DIR/dsh-web-doctor/scripts/session-last-activity.mjs" ]; then
  node "$SKILLS_DIR/dsh-web-doctor/scripts/session-last-activity.mjs" --limit 4 2>&1 | sed 's/^/  /'
fi

# --- 4. repair ---------------------------------------------------------------
if [ "$FLAG_FIX" = "1" ]; then
  echo
  info "== auto-fix =="

  # 4a. relink + launcher self-heal via ab.sh status (idempotent, read-mostly)
  if [ -x "$AB" ]; then
    if "$AB" status >/dev/null 2>&1; then
      ok "ab.sh status ran (relink self-heal active)"
    else
      warn "ab.sh status exited non-zero (see above)"
    fi
  fi

  # 4b. slot launcher materialization (20260811+ slots have no bin/dsh)
  if [ -n "$CURRENT" ] && [ ! -x "$CURRENT/bin/dsh" ] && [ -x "$CURRENT/apps/cli/lib/bin.js" ]; then
    mkdir -p "$CURRENT/bin"
    cat > "$CURRENT/bin/dsh" <<'LAUNCHER'
#!/bin/sh
# slot launcher for snapshots without bin/dsh (20260811+): boots the compiled
# CLI entry apps/cli/lib/bin.js (production node ESM). Regenerated by
# dsh-web-doctor / ab.sh prepare.
set -eu
script=$0
while [ -L "$script" ]; do
  target=$(readlink "$script")
  case $target in
    /*) script=$target ;;
    *) script=$(dirname "$script")/$target ;;
  esac
done
root=$(CDPATH='' cd -- "$(dirname -- "$script")/.." && pwd)
exec node "$root/apps/cli/lib/bin.js" "$@"
LAUNCHER
    chmod +x "$CURRENT/bin/dsh"
    ok "materialized $CURRENT/bin/dsh (compiled CLI entry)"
  fi

  # 4c. unknown session-event repair (ignorable marking)
  if [ -f "$REC/repair-unknown-events.mjs" ]; then
    node "$REC/repair-unknown-events.mjs" --all >/tmp/dsh-doctor-repair.log 2>&1
    rc=$?
    if [ "$rc" = "0" ] || [ "$rc" = "2" ]; then
      tail -1 /tmp/dsh-doctor-repair.log | sed 's/^/  /'
      ok "unknown-event repair pass complete"
    else
      err "unknown-event repair failed (see /tmp/dsh-doctor-repair.log)"
      note_problem
    fi
  fi

  # --- 4d. verify fixes (re-check what we just repaired) -----------------------
  echo
  info "== verify fixes =="
  PROBLEMS=0
  if [ -f "$DSH_SOURCE/ab-config.json" ] && [ -n "$CURRENT" ]; then
    missing=$(python3 - "$DSH_SOURCE/ab-config.json" "$CURRENT" <<'PY'
import json, os, sys
cfg, cur = sys.argv[1], sys.argv[2]
d = json.load(open(cfg))
miss = 0
for ext in d.get('extensions', []):
    repo = ext.get('repo', '')
    for link, _rel in (ext.get('relink') or {}).items():
        if not os.path.exists(f"{repo}/{link}"):
            print(f"  MISSING {repo}/{link}")
            miss += 1
sys.exit(1 if miss else 0)
PY
    )
    rc=$?
    if [ "$rc" = "0" ]; then
      ok "all extension relinks present"
    else
      err "relinks still missing:"; printf '%s\n' "$missing" | sed 's/^/    /'
      note_problem
    fi
  fi
  if [ -n "$CURRENT" ] && { [ ! -x "$CURRENT/bin/dsh" ] && [ ! -x "$CURRENT/apps/cli/lib/bin.js" ]; }; then
    err "current slot still not bootable"
    note_problem
  fi
fi

# --- 5. restart --------------------------------------------------------------
if [ "$FLAG_RESTART" = "1" ]; then
  echo
  info "== relaunching dsh web (port $PORT) =="
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then
    ok "web already up — skipping restart"
  elif [ -f "$REC/restart-dsh-web.sh" ]; then
    sh "$REC/restart-dsh-web.sh" 2>&1 | tail -6
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then
      ok "web is UP on :$PORT after restart"
    else
      err "web NOT up after restart (HTTP $code) — inspect the log tail above"
      exit 2
    fi
  else
    err "restart-dsh-web.sh missing — cannot relaunch"
    exit 2
  fi
fi

# --- 6. report ---------------------------------------------------------------
echo
info "== report =="
if [ "$PROBLEMS" = "0" ]; then
  ok "no problems found"
  exit 0
else
  err "$PROBLEMS problem(s) found"
  if [ "$FLAG_FIX" = "0" ]; then
    say "  re-run with --fix to auto-repair, --restart to relaunch web"
  fi
  exit 1
fi
