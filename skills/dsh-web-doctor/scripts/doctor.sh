#!/usr/bin/env bash
# dsh-web-doctor — OUT-OF-BAND diagnosis, repair and relaunch for dsh web.
#
# Use this when the web (3080) is down or won't boot — including when BOTH A/B
# slots are broken — and the normal GUI/agent path is unavailable. It runs
# entirely from the terminal with local tools (node/zstd/jq/curl/ps/lsof) and
# the installed skills' scripts; it does NOT depend on a running web process.
#
# USER-FIRST: run `dsh-doctor` with NO arguments → an interactive menu shows
# the web status and the things you can do. No flags to remember:
#   1. quick check (read-only)     2. deterministic fix + relaunch (no LLM)
#   3. LLM self-heal (recommended)  4. deep LLM check & repair (always runs)
#   7. mini TUI — guided mode (you confirm every fix step by step; no
#      unattended long runs unless you explicitly choose the LLM step)
#
# Why mini TUI (2026-08-13): an unattended `--agent` run once burned its whole
# timeout chasing a false-positive plugin-dep report and a misleading "slot may
# be broken" hint, fixing nothing. Lesson: long doctor tasks without a human
# steering them are unreliable. Guided mode shows every finding and asks
# [Y]es/[n]o/[?]detail/[q]uit before each fix; the LLM step is optional
# (read-only review, or explicit unattended repair with a hard timeout).
#
# Flag mode (for scripts / advanced use) is unchanged:
#   doctor.sh                 # diagnose only (read-only)
#   doctor.sh --fix           # diagnose + deterministic auto-fix
#   doctor.sh --fix --restart # diagnose + fix + relaunch web
#   doctor.sh --agent         # diagnose + LLM brain (headless one-shot)
#   doctor.sh --guide         # mini TUI — human-guided, step-by-step
#   doctor.sh --quiet         # less chatter
#
# DEPENDENCY LAYERS (minimal-dependency by design — the doctor must keep
# working when the things it would fix are broken):
#   L0 (self-contained, never fails on its own): system tools + node built-ins
#      + zstd CLI + plain file ops. Covers: layout snapshot, web health,
#      launcher chain, extension relink existence, slot bootability, session
#      FILE-layer check (session-store-check.mjs), last-activity, relink +
#      launcher repair, built-in restart fallback. No DSH compiled package and
#      no extension bundle is ever loaded by L0.
#   L1 (deep, degrades gracefully): compiled-reader checks and repairs
#      (check-all-sessions, repair-unknown-events). These need the current
#      slot's compiled packages; if they cannot load, the doctor reports the
#      ACTUAL error and keeps going — L0 conclusions stay authoritative (a
#      deep-check failure is environment noise, NOT proof the slot is broken).
#   LLM (--agent / guided LLM step): one-shot headless agent (dsh --profile
#      headless) reads the deterministic report + logs, reasons the root cause
#      (adapts to DSH changes), fixes, and relaunches. Headless does NOT load
#      the web's extension bundles (dsh-track etc. are web-profile only), so
#      extension dependency faults do not stop the LLM brain; it DOES load
#      skills (~/.dsh/skills) and depends on the current slot's compiled
#      packages and LLM credentials — when those are broken, --fix (L0) is the
#      fallback.
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
REPORT="${DSH_DOCTOR_REPORT:-/tmp/dsh-doctor-report.txt}"

FLAG_FIX=0; FLAG_RESTART=0; FLAG_QUIET=0; FLAG_AGENT=0; FLAG_FORCE=0; FLAG_GUIDE=0; FLAG_DIAG_JSON=0; FLAG_FIX_ITEM=
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FLAG_FORCE=1; shift ;;
    --help|-h)
      cat <<'HELP'
dsh web Doctor — 一键救火（web 挂了 / 起不来时用）

用法（不用记，直接跑 dsh-doctor 就有交互菜单）：
  dsh-doctor                    交互菜单（推荐）
  dsh-doctor --guide            mini TUI（全屏交互终端）：诊断流式输出 →
                                自动修复 → LLM 自动运行（markdown 渲染 CoT，
                                随时 Ctrl-C 打断并输入指引）
  dsh-doctor --agent            LLM 智能自愈（诊断+找根因+修复+拉起 web）
  dsh-doctor --agent --force     强制 LLM 验收（即使诊断全绿也跑 LLM 交叉验证）
  dsh-doctor --fix --restart    确定性修复 + 拉起 web（不依赖 LLM）
  dsh-doctor --fix              只确定性修复
  dsh-doctor --quiet            少输出

内部子命令（TUI 驱动用，勿手敲）：
  dsh-doctor --diag-json        诊断结果 JSON（web/problems）
  dsh-doctor --fix-item <kind>  只跑单个修复原语（web/launcher/relink/boot/session/pdep/llm）

入口（二选一，都行）：
  dsh-doctor                    # PATH 命令（~/.local/bin/dsh-doctor，与 dsh 同目录）
  ~/.dsh/source/current/bin/dsh-doctor   # 槽 bin 内（prepare 后自动保留）
HELP
      exit 0 ;;
    --fix) FLAG_FIX=1; shift ;;
    --restart) FLAG_RESTART=1; shift ;;
    --agent) FLAG_AGENT=1; shift ;;
    --guide|--tui) FLAG_GUIDE=1; shift ;;
    --diag-json) FLAG_DIAG_JSON=1; shift ;;
    --fix-item) FLAG_FIX_ITEM="${2:-}"; shift 2 ;;
    --quiet) FLAG_QUIET=1; shift ;;
    *) echo "unknown arg: $1 (try: dsh-doctor --help)" >&2; exit 2 ;;
  esac
done

say()  { [ "$FLAG_QUIET" = "1" ] || printf '%s\n' "$*"; }
warn() { printf '\033[1;33m[doctor]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[doctor]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[doctor]\033[0m %s\n' "$*"; }
info() { printf '\033[1;34m[doctor]\033[0m %s\n' "$*"; }

LANG_CODE="${DSH_DOCTOR_LANG:-en}"

# ---------------------------------------------------------------------------
# Structured problem ledger — every diagnosis check records "id|hint" entries
# so the guided mode can walk them one by one (id → fix primitive).
# ---------------------------------------------------------------------------
PROBLEMS=0
PROBLEM_LIST=()
SESSION_FAILS=()
note_problem() {
  PROBLEMS=$((PROBLEMS + 1))
  [ $# -ge 1 ] && PROBLEM_LIST+=("$1")
}

# ---------------------------------------------------------------------------
# fix_llm_config — LLM credentials/config repair with interactive key input.
# The goal is to CONFIGURE it, not just hint: if DEEPSEEK_API_KEY is
# missing/empty and a terminal is available, ask the user to paste the key
# (hidden input), back up .env, write it, chmod 600. settings.yaml that is
# empty/corrupt is backed up and reset to a minimal {}. Non-interactive runs
# print the exact command instead. The key itself is user-owned — doctor
# guides and configures, never invents.
# ---------------------------------------------------------------------------
fix_llm_config() {
  local env_file="$HOME/.dsh/.env" settings_file="$HOME/.dsh/settings.yaml"
  local have_key=0
  [ -f "$env_file" ] && grep -qE '^DEEPSEEK_API_KEY=.+$' "$env_file" 2>/dev/null && have_key=1

  if [ "$have_key" = "1" ]; then
    chmod 600 "$env_file" 2>/dev/null
    ok "  LLM: DEEPSEEK_API_KEY present in ~/.dsh/.env (permissions 600)"
  else
    mkdir -p "$HOME/.dsh"
    [ -f "$env_file" ] && cp "$env_file" "$env_file.bak-$(date +%s)" 2>/dev/null
    if [ -t 0 ]; then
      printf '  DEEPSEEK_API_KEY is missing/empty. Paste your API key (input hidden): '
      read -r -s api_key || { echo; err "  aborted — no key entered"; return 1; }
      echo
      if [ -n "$api_key" ]; then
        grep -v '^DEEPSEEK_API_KEY=' "$env_file" 2>/dev/null > "$env_file.tmp" || true
        printf 'DEEPSEEK_API_KEY=%s\n' "$api_key" >> "$env_file.tmp"
        mv "$env_file.tmp" "$env_file"
        chmod 600 "$env_file"
        ok "  LLM: DEEPSEEK_API_KEY configured in ~/.dsh/.env (old file backed up)"
      else
        err "  no key entered — skipped"
      fi
    else
      warn "  DEEPSEEK_API_KEY missing — doctor needs it for web/headless; configure with:"
      warn "    echo 'DEEPSEEK_API_KEY=<your-key>' >> ~/.dsh/.env   (then restart web)"
    fi
  fi

  # settings.yaml: empty/corrupt → backup + minimal default (a corrupt
  # settings file can keep the web from booting; {} is a safe temporary fix)
  if [ -f "$settings_file" ]; then
    if [ -s "$settings_file" ]; then
      say "  settings.yaml present"
    else
      cp "$settings_file" "$settings_file.bak-$(date +%s)" 2>/dev/null
      printf '{}\n' > "$settings_file"
      warn "  settings.yaml was empty/corrupt — backed up, reset to {} (temporary fix)"
    fi
  else
    printf '{}\n' > "$settings_file"
    say "  settings.yaml created (minimal {})"
  fi
}

# ---------------------------------------------------------------------------
# Fix primitives — one function per repair, shared by the auto-fix path
# (doctor_run --fix) and the guided mode. Every one is idempotent, reversible
# or backed up by the underlying script.
# ---------------------------------------------------------------------------
restart_web() {
  info "== relaunching dsh web (port $PORT) =="
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || true); code=${code:-000}
  if [ "$code" = "200" ]; then
    ok "web already up — skipping restart"
    return 0
  fi
  if [ -f "$REC/restart-dsh-web.sh" ]; then
    sh "$REC/restart-dsh-web.sh" >/tmp/dsh-doctor-restart.log 2>&1
    say "  restart script: $(tail -2 /tmp/dsh-doctor-restart.log | tr '\n' ' ')"
  else
    say "  restarting with doctor's built-in fallback (no recovery skill present)..."
    local local_pids
    local_pids=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null)
    [ -n "$local_pids" ] && kill -TERM $local_pids 2>/dev/null || true
    i=0; while [ "$i" -lt 30 ] && lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do i=$((i+1)); sleep 1; done
    ( cd "$HOME" && nohup dsh web >/tmp/dsh-web-restart.log 2>&1 & )
  fi
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:$PORT/" 2>/dev/null || true); code=${code:-000}
  if [ "$code" = "200" ]; then
    ok "web is UP on :$PORT after restart"
    return 0
  fi
  err "web NOT up after restart (HTTP $code) — inspect the log tail above"
  return 1
}

fix_relink_selfheal() {
  if [ -x "$AB" ]; then
    if "$AB" status >/dev/null 2>&1; then
      ok "ab.sh status ran (relink self-heal active)"
      return 0
    fi
    warn "ab.sh status exited non-zero (see above)"
    return 1
  fi
  warn "ab.sh not found — cannot relink self-heal"
  return 1
}

# slot launcher materialization (20260811+ slots have no bin/dsh)
fix_launcher() {
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
    return 0
  fi
  if [ -n "$CURRENT" ] && [ -x "$CURRENT/bin/dsh" ]; then
    ok "slot launcher already present ($CURRENT/bin/dsh)"
    return 0
  fi
  err "current slot has neither bin/dsh nor apps/cli/lib/bin.js — not bootable"
  return 1
}

# unknown session-event repair (ignorable marking) — DEEP layer
fix_unknown_events() {
  if [ -f "$REC/repair-unknown-events.mjs" ]; then
    node "$REC/repair-unknown-events.mjs" --all >/tmp/dsh-doctor-repair.log 2>&1
    local rc=$?
    if [ "$rc" = "0" ] || [ "$rc" = "2" ]; then
      tail -1 /tmp/dsh-doctor-repair.log | sed 's/^/  /'
      ok "unknown-event repair pass complete"
      return 0
    fi
    err "unknown-event repair could not run (deep layer needs the compiled DSH reader; likely the current slot is broken)."
    err "  diagnose the slot first; the repair itself: node $REC/repair-unknown-events.mjs --all"
    return 1
  fi
  warn "repair-unknown-events.mjs not found"
  return 1
}

# generic plugin dependency self-heal (any bundle; source auto-found in the
# current slot's packages by package name — no ab-config mapping)
fix_plugin_deps() {
  local pdep="$SKILLS_DIR/dsh-web-doctor/scripts/plugin-deps-check.mjs"
  local fixed=0
  if [ ! -f "$pdep" ]; then
    warn "plugin-deps-check.mjs not found"
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      FIXABLE:*)
        pkg=$(printf '%s' "$line" | sed 's/FIXABLE: \([^ ]*\).*/\1/')
        # FIXABLE 可能带子路径（如 @deepseek-ai/dsh-x/client）：只取包名前两段，
        # 否则 mkdir + ln 会建出「包目录/子路径」的错误链接形态。
        pkg=$(printf '%s' "$pkg" | sed 's#^\(@[^/]*/[^/]*\)/.*#\1#')
        repo=$(printf '%s' "$line" | sed 's/.*repo=\([^ ]*\).*/\1/')
        src=$(printf '%s' "$line" | sed 's/.*-> //')
        link="$repo/node_modules/$pkg"
        mkdir -p "$(dirname "$link")"
        ln -sfn "$src" "$link"
        ok "  plugin dep self-heal: $link -> $src"
        fixed=$((fixed + 1))
        ;;
    esac
  done < <(node "$pdep" 2>&1)
  [ "$fixed" = "0" ] && { warn "  no FIXABLE plugin deps to heal (MISSING-only issues need manual action)"; return 1; }
  return 0
}

# lossless repair of the session logs the file-layer check flagged
fix_sessions() {
  local repaired=0
  if [ ! -f "$REC/repair-session-log.mjs" ]; then
    warn "repair-session-log.mjs not found — cannot repair sessions"
    return 1
  fi
  for f in "${SESSION_FAILS[@]:-}"; do
    local sid
    sid=$(printf '%s' "$f" | sed 's/^FAIL //; s/:.*//')
    [ -z "$sid" ] && continue
    node "$REC/repair-session-log.mjs" --id "$sid" >/tmp/dsh-doctor-session-repair.log 2>&1
    local rc=$?
    if [ "$rc" = "0" ] || [ "$rc" = "2" ]; then
      ok "  session repaired/valid: $sid"
      repaired=$((repaired + 1))
    else
      err "  session repair FAILED for $sid — see /tmp/dsh-doctor-session-repair.log"
    fi
  done
  [ "$repaired" = "0" ] && warn "  no session repaired (see session-store-check output above)"
  return 0
}

# ---------------------------------------------------------------------------
# doctor_diagnose — one read-only pass: environment → layout → diagnosis →
# populates PROBLEMS / PROBLEM_LIST / SESSION_FAILS. Shared by every mode.
# ---------------------------------------------------------------------------
doctor_diagnose() {
  PROBLEMS=0
  PROBLEM_LIST=()
  SESSION_FAILS=()

  # --- 1. environment --------------------------------------------------------
  info "dsh-web-doctor (out-of-band) — port $PORT"
  local missing=""
  for t in node zstd jq curl ps lsof; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  if [ -n "$missing" ]; then
    err "missing required tools:$missing — doctor cannot run"
    exit 2
  fi

  # --- 2. layout snapshot ----------------------------------------------------
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
  [ -n "$CURRENT" ] || { err "no current symlink — the A/B layout is missing"; note_problem "layout|no current symlink — the A/B layout is missing"; }

  # --- 3. diagnosis ----------------------------------------------------------
  echo
  info "== diagnosis =="

  # 3a. web health
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || true); code=${code:-000}
  if [ "$code" = "200" ]; then
    ok "web on :$PORT answers HTTP 200"
  else
    err "web on :$PORT answers HTTP $code (not up)"
    note_problem "web|web on :$PORT answers HTTP $code — not up"
  fi

  # 3b. launcher chain
  launcher=$(command -v dsh || true)
  if [ -n "$launcher" ]; then
    resolved=$(readlink "$launcher" 2>/dev/null || echo "$launcher")
    say "  launcher: $launcher -> $resolved"
    # `current` is a symlink; readlink does not recurse, so accept both the
    # real slot path and the `$DSH_SOURCE/current/...` spelling.
    if [ -n "$CURRENT" ] && [[ "$resolved" != "$CURRENT/"* ]] && [[ "$resolved" != "$DSH_SOURCE/current/"* ]]; then
      warn "launcher resolves outside current slot ($resolved)"
    fi
    if [ -f "$launcher" ] && [ ! -x "$launcher" ]; then
      err "launcher exists but is not executable: $launcher"
      note_problem "launcher|launcher exists but is not executable: $launcher"
    fi
  else
    err "'dsh' not on PATH — launcher chain broken"
    note_problem "launcher|'dsh' not on PATH — launcher chain broken"
  fi

  # 3c. extension relinks (against current)
  if [ -f "$DSH_SOURCE/ab-config.json" ]; then
    echo
    say "== extension relinks =="
    relink_out=$(python3 - "$DSH_SOURCE/ab-config.json" "$CURRENT" <<'PY'
import json, os, sys
cfg, cur = sys.argv[1], sys.argv[2]
d = json.load(open(cfg))
miss = 0
for ext in d.get('extensions', []):
    repo = ext.get('repo', '')
    for link, rel in (ext.get('relink') or {}).items():
        target = f"{repo}/{link}"
        if not os.path.exists(target):
            print(f"MISSING: relink {target} (needs -> {cur}/{rel})")
            miss = 1
        else:
            print(f"ok: {link} -> {rel}")
sys.exit(1 if miss else 0)
PY
    )
    rc=$?
    if [ -n "$relink_out" ]; then
      while IFS= read -r line; do
        case "$line" in
          MISSING:*) err "$line"; note_problem "relink|$line" ;;
          *) say "  $line" ;;
        esac
      done <<< "$relink_out"
    fi
  fi

  # 3d. slot bootable
  if [ -n "$CURRENT" ]; then
    echo
    say "== current slot bootability =="
    if [ -x "$CURRENT/bin/dsh" ]; then
      say "  bin/dsh present"
    elif [ -x "$CURRENT/apps/cli/lib/bin.js" ]; then
      warn "  no bin/dsh — compiled CLI present (launcher chain may still break if bin/dsh is what ~/.local/bin/dsh resolves to)"
      note_problem "boot|no bin/dsh in current slot (compiled CLI present — launcher chain may break)"
    else
      err "  current slot has neither bin/dsh nor apps/cli/lib/bin.js — not bootable"
      note_problem "boot|current slot has neither bin/dsh nor apps/cli/lib/bin.js — not bootable"
    fi
  fi

  # 3e. session store health — L0 self-contained check FIRST (file layer only:
  # node built-ins + zstd CLI, no DSH compiled packages — works even when the
  # current slot / its build artifacts are broken). The compiled-reader deep
  # check (check-all-sessions) is an OPTIONAL enhancement; when it fails we
  # show the ACTUAL error — a deep-check failure is environment noise, not
  # proof the slot is broken (2026-08-13: the old generic message sent the LLM
  # agent down rabbit holes).
  echo
  say "== session store (file-layer, minimal deps) =="
  local L0="$SKILLS_DIR/dsh-web-doctor/scripts/session-store-check.mjs"
  if [ -f "$L0" ]; then
    local out tail_line
    out=$(node "$L0" 2>&1); local rc=$?
    while IFS= read -r line; do
      case "$line" in
        FAIL\ *) SESSION_FAILS+=("$line") ;;
      esac
    done <<< "$out"
    tail_line=$(printf '%s\n' "$out" | tail -1)
    if [ "$rc" = "0" ]; then
      ok "sessions: $tail_line"
    else
      err "sessions: $tail_line"
      note_problem "session|sessions: $tail_line"
    fi
  else
    err "session-store-check.mjs missing — session store not checked"
    note_problem "session|session-store-check.mjs missing — session store not checked"
  fi
  if [ -f "$REC/check-all-sessions.mjs" ]; then
    deep=$(node "$REC/check-all-sessions.mjs" 2>&1); drc=$?
    if [ "$drc" = "0" ]; then
      say "  deep check (compiled reader): $(printf '%s\n' "$deep" | tail -1)"
    else
      err "  deep check failed: $(printf '%s\n' "$deep" | tail -1)"
      warn "  (enhanced check — the file-layer check above is authoritative; failure usually means the compiled reader can't load in THIS environment, NOT that the slot is broken)"
    fi
  fi

  # 3f. web.log tail + boot-failure hints, classified: historical vs current
  if [ -f "$DSH_SOURCE/web.log" ]; then
    echo
    say "== web.log tail =="
    tail -8 "$DSH_SOURCE/web.log" | sed 's/^/  /' >&2
    # web up => the errors below are from PREVIOUS boots (e.g. the 2026-08-11
    # 'exec: node: not found' residue), not the current fault; web down =>
    # they are the likely current cause.
    if [ "$code" = "200" ]; then
      say "  note: web is UP — errors above are HISTORICAL (previous boot failures), not the current fault"
    else
      warn "  web is DOWN — errors above are likely the CURRENT fault"
    fi
    boot_err=$(grep -oE "Cannot find package '[^']+'|failed to import loader entry [a-zA-Z_-]+|plugin tree failed to load[^;]*" "$DSH_SOURCE/web.log" 2>/dev/null | tail -3)
    if [ -n "$boot_err" ]; then
      echo
      warn "  boot failure hints:"
      printf '%s\n' "$boot_err" | sed 's/^/    /' >&2
    fi
  fi

  # 3g. generic plugin dependency check — ANY out-of-tree bundle in the web
  #     profile (not just ab-config'd ones): dsh-loop, dsh-kb-sieve, whatever
  #     gets installed later. A missing dep here is a boot-killer.
  local PDEPS="$SKILLS_DIR/dsh-web-doctor/scripts/plugin-deps-check.mjs"
  if [ -f "$PDEPS" ]; then
    echo
    say "== profile bundles dependency check =="
    while IFS= read -r line; do
      case "$line" in
        FIXABLE:*) warn "  $line"; note_problem "pdep|$line" ;;
        MISSING:*) err "  $line"; note_problem "pdep|$line" ;;
        ok:*) say "  $line" ;;
      esac
    done < <(node "$PDEPS" 2>&1)
  fi

  # 3i. LLM credentials health — web AND headless both need a working LLM
  #     config; the credential chain is: process env > cwd/.env >
  #     $DSH_HOME/.env (DEEPSEEK_API_KEY). We never print the key itself.
  echo
  say "== LLM config =="
  if [ -f "$HOME/.dsh/.env" ]; then
    if grep -qE '^DEEPSEEK_API_KEY=.+$' "$HOME/.dsh/.env" 2>/dev/null; then
      ok "  DEEPSEEK_API_KEY present in ~/.dsh/.env"
    else
      err "  ~/.dsh/.env exists but DEEPSEEK_API_KEY is empty/missing"
      note_problem "llm|~/.dsh/.env exists but DEEPSEEK_API_KEY is empty/missing"
    fi
  else
    err "  ~/.dsh/.env missing — no LLM credentials (web/headless cannot call an LLM)"
    note_problem "llm|~/.dsh/.env missing — no LLM credentials"
  fi
  [ -f "$HOME/.dsh/settings.yaml" ] && say "  settings.yaml present" || warn "  settings.yaml missing (non-fatal)"

  # 3h. what happened last (most recently active sessions)
  echo
  say "== last activity in recent sessions =="
  if [ -f "$SKILLS_DIR/dsh-web-doctor/scripts/session-last-activity.mjs" ]; then
    node "$SKILLS_DIR/dsh-web-doctor/scripts/session-last-activity.mjs" --limit 4 2>&1 | sed 's/^/  /'
  fi
}

# ---------------------------------------------------------------------------
# run_agent — the LLM brain. One-shot headless agent (dsh --profile headless),
# live-streaming its own session log (full reasoning chain) while it works.
#   mode=repair : the self-heal prompt (--agent)
#   mode=force  : same, but never skips even when diagnosis is all green
#   mode=review : READ-ONLY cross-check — verifies the deterministic findings
#                 and lists anything missed; changes nothing (guided default)
# Ctrl-C stops the agent (not just the watcher); a hard outer timeout never
# lets a stuck agent hang the user.
# ---------------------------------------------------------------------------
AGENT_TASK=$(cat <<'PROMPT'
你是 dsh web 的 out-of-band 自愈 agent（one-shot）。web（3080）挂了或状态异常，
由你诊断根因、修复、把 web 拉回来。headless 模式下你可用工具读文件/执行命令。
（若本 prompt 是 mini TUI 引导模式触发的：确定性修复已先执行并验证过，你要做的是
找出它们漏掉的问题，而不是重复调查已确认健康的东西。）

步骤：
0. 先看报告里的 LLM config 段：若 DEEPSEEK_API_KEY 缺失/为空（~/.dsh/.env），
   提示用户补 key（echo 'DEEPSEEK_API_KEY=<key>' >> ~/.dsh/.env），不要臆造凭据；
   key 在则继续。
1. 读 /tmp/dsh-doctor-report.txt —— dsh-doctor 的确定性体检报告
   （web/launcher/relink/槽可启动/session 文件层/web.log 尾部/LLM config/最近活动）。
2. 读 ~/.dsh/skills/dsh-web-doctor/SKILL.md —— 可用修复原语说明。
3. 需要更深入时：node ~/.dsh/skills/dsh-web-doctor/scripts/session-last-activity.mjs
   看最近会话最后发生的事；tail ~/.dsh/source/web.log（注意 web.log 可能含历史
   残留，判断是否当前故障看时间戳和当前 web 是否 200）。
4. 找根因 → 修复。优先复用确定性原语：
   bash ~/.dsh/skills/dsh-web-doctor/scripts/doctor.sh --fix
   （relink 自愈 / 插件依赖自愈 / bin/dsh 补位 / 未知事件 ignorable / 损坏日志修复）；
   也可直接执行修复命令。
   若是【任何插件】导致 boot 失败（报错含 Cannot find package / failed to import
   loader entry / plugin tree failed to load）：
   a. 读 ~/.dsh/profiles/web/package.json 的 dependencies/bundles 定位是哪个插件；
   b. 修其依赖（node ~/.dsh/skills/dsh-web-doctor/scripts/plugin-deps-check.mjs
      看 FIXABLE/MISSING；MISSING 且槽里没有 → 该插件缺依赖，需重装或隔离）；
   c. 必要时隔离该插件（dsh plugin --profile web remove <pkg>）让 web 先起来，
      再单独修插件。
5. 验证：curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/ 应为 200；
   若 web 未起，用 restart-dsh-web.sh 或 nohup dsh web 拉起。
6. 最终输出（简洁中文）：根因一句话、做了什么、当前 web 状态；
   若无法修复：卡在哪一步、缺什么、需要用户做什么。
7. 若报告显示全绿（forced acceptance）：不要只复述报告——**独立交叉验证**
   每一项（curl、launcher 链、relink、session、LLM key、守护进程），
   确认健康后输出"验收通过"及你验证过的证据清单；发现报告漏掉的再报。

纪律（2026-08-13 教训，必须遵守）：
- 确定性报告里的某些 "unavailable / 失败" 可能是环境性噪音（如 deep check 的
  compiled reader 加载失败、web.log 历史残留、session 深度检查加载失败），
  **不是槽坏了的证据**。先看具体报错，与当前故障无关就标注并继续，
  不要钻牛角尖。
- 每执行一步修复前先验证当前状态；连续 3-4 步没有进展就停止深挖，
  输出：已查证的事实、最可能的根因、卡点、下一步建议。
- 只做必要修复，不动用户数据；不确定的操作先读报告/日志再决定。
  不要臆造；查不到就明说。
PROMPT
)

AGENT_TASK_REVIEW=$(cat <<'PROMPT'
你是 dsh web 的**只读复核** agent（read-only review）。web 的确定性体检已经
跑完（/tmp/dsh-doctor-report.txt），你**不修改任何文件、不执行任何修复**，
只做独立交叉验证与补充：

1. 读 /tmp/dsh-doctor-report.txt —— 确定性体检报告。
2. 独立验证关键项（不依赖报告的结论）：
   - curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/
   - command -v dsh；~/.local/bin/dsh 解析链（readlink）
   - ab-config 里 extension relink 的存在性（ls 对应路径）
   - ~/.dsh/.env 是否有非空 DEEPSEEK_API_KEY（不要打印 key 本身）
   - ~/.dsh/source/web.log 尾部（区分历史残留与当前故障）
3. 找出确定性检查**漏掉**的问题（若有），每个给出证据（命令/文件路径）。
4. 最终输出（简洁中文）：① 验证结果（每项 ✓/✗）② 漏掉的问题列表
   （无则明确说"无"）③ 若发现严重问题，给出建议的修复命令（但你不执行）。

约束：**只读**。不要运行任何会修改文件/配置/进程的命令。
PROMPT
)

run_agent() {
  local mode="${1:-repair}"
  echo
  info "== LLM brain (mode: $mode) =="
  local code_now
  code_now=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || true); code_now=${code_now:-000}
  if [ "$PROBLEMS" = "0" ] && [ "$code_now" = "200" ] && [ "$mode" != "force" ] && [ "$mode" != "review" ]; then
    ok "diagnosis is all green and web is UP — LLM brain not needed (use --force or guided 'review' to force)"
    return 0
  fi
  if ! command -v dsh >/dev/null 2>&1; then
    err "'dsh' not on PATH — cannot launch the headless agent (fall back to: dsh-doctor --fix --restart)"
    return 1
  fi
  if ! dsh --profile headless --help >/dev/null 2>&1; then
    err "'dsh --profile headless' unavailable — LLM brain cannot start (fall back to: dsh-doctor --fix --restart)"
    return 1
  fi

  local task="$AGENT_TASK"
  [ "$mode" = "review" ] && task="$AGENT_TASK_REVIEW"
  ok "launching headless LLM agent (report: $REPORT)"
  say "  watching its live session log below; final answer appears when it finishes (Ctrl-C to stop):"
  # the agent writes its own session log as it works (reasoning chunks,
  # tool calls, generated text) — tail that so the user SEES it working.
  # the web's own session (current chat) is also being written constantly —
  # the agent's session is the NEW one that did not exist before launch.
  local before_list newest agent_log total last_pos=0 waited=0 APID
  before_list=$(find "$HOME/.dsh/sessions" -name session.jsonl.zstd 2>/dev/null)
  ( DSH_PERMISSION_MODE=danger-full-access dsh --profile headless "$task" 2>&1 | sed 's/^/  [agent] /' ) &
  APID=$!
  agent_cleanup() {
    [ -n "${APID:-}" ] && { kill "$APID" 2>/dev/null; pkill -P "$APID" 2>/dev/null; }
    err "interrupted — LLM agent stopped"
    exit 130
  }
  trap agent_cleanup INT
  local AGENT_TIMEOUT="${DSH_DOCTOR_AGENT_TIMEOUT:-300}"
  [ "$mode" = "review" ] && AGENT_TIMEOUT="${DSH_DOCTOR_REVIEW_TIMEOUT:-150}"
  while kill -0 "$APID" 2>/dev/null && [ "$waited" -lt "$AGENT_TIMEOUT" ]; do
    sleep 2; waited=$((waited+2))
    # live stream: the headless agent writes its OWN session log as it
    # works — reasoning chain (CoT), tool calls, generated text. Read the
    # NEW lines since the last tick and print their full content.
    newest=$(ls -t "$HOME"/.dsh/sessions/*/*/session.jsonl.zstd 2>/dev/null | head -1)
    if [ -n "$newest" ] && ! printf '%s\n' "$before_list" | grep -qxF "$newest"; then
      agent_log="$newest"
      total=$(zstd -dc "$newest" 2>/dev/null | wc -l | tr -d ' ')
      if [ "${total:-0}" -gt "$last_pos" ] 2>/dev/null; then
        zstd -dc "$newest" 2>/dev/null | tail -n +$((last_pos + 1)) | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    t = d.get("type", "?")
    data = d.get("data", {}) or {}
    txt = ""
    if t == "reasoning-chunks":
        txt = "".join(data.get("texts") or [data.get("text", "")] or []).strip()
    elif t in ("assistant/chunk", "text-chunks"):
        txt = "".join(data.get("texts") or [data.get("text", "")] or []).strip()
    elif t == "tool/call":
        a = data.get("arguments", data.get("input", ""))
        txt = ("tool " + str(data.get("name", "?")) + " " + (str(a)[:120] if isinstance(a, str) else ""))
    elif t == "tool/result":
        txt = "tool result"
    elif t in ("step/start", "step/end", "turn/start"):
        txt = ""
    elif t == "user/message":
        c = data.get("content", "")
        txt = (str(c)[:120] if not isinstance(c, list) else "prompt issued")
    if txt:
        for ln in txt.splitlines():
            if ln.strip():
                print("  [llm] " + ln.strip())
' 2>/dev/null
        last_pos=$total
      fi
    fi
  done
  trap - INT
  if kill -0 "$APID" 2>/dev/null; then
    err "LLM agent timed out after ${waited}s (DSH_DOCTOR_AGENT_TIMEOUT) — it may be stuck; fall back to: dsh-doctor --fix --restart"
    kill "$APID" 2>/dev/null; pkill -P "$APID" 2>/dev/null
    return 1
  fi
  wait "$APID" 2>/dev/null || true
  say "  LLM agent finished (~${waited}s)"
  return 0
}

# ---------------------------------------------------------------------------
# doctor_run — one flag-driven pass: diagnose → (fix) → (restart) → (agent) →
# report. Flags decide which stages run.
# ---------------------------------------------------------------------------
doctor_run() {
  doctor_diagnose

  # --- 4. repair ---------------------------------------------------------------
  if [ "$FLAG_FIX" = "1" ]; then
    echo
    info "== auto-fix =="
    if [ "$PROBLEMS" = "0" ]; then
      ok "diagnosis found no problems — skipping repair (no mechanical fix needed)"
    else

    # 4a. relink + launcher self-heal via ab.sh status (idempotent, read-mostly)
    fix_relink_selfheal

    # 4b. slot launcher materialization (20260811+ slots have no bin/dsh)
    fix_launcher

    # 4c. unknown session-event repair (ignorable marking) — DEEP layer
    fix_unknown_events

    # 4d. generic plugin dependency self-heal (any bundle)
    fix_plugin_deps

    # 4e. LLM credentials/config repair — interactive key input when possible
    echo
    info "== LLM config repair =="
    fix_llm_config
    if ! grep -qE '^DEEPSEEK_API_KEY=.+$' "$HOME/.dsh/.env" 2>/dev/null; then
      note_problem
    fi

    # --- 4f. verify fixes (re-check what we just repaired) ---------------------
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
    fi   # end of the "problems found -> repair" branch
  fi

  # --- 5. restart --------------------------------------------------------------
  if [ "$FLAG_RESTART" = "1" ]; then
    restart_web || exit 2
  fi

  # --- 5b. LLM brain -----------------------------------------------------------
  if [ "$FLAG_AGENT" = "1" ]; then
    if [ "$FLAG_FORCE" = "1" ]; then
      run_agent force
    else
      run_agent repair
    fi
  fi

  # --- 6. report ---------------------------------------------------------------
  echo
  info "== report =="
  if [ "$PROBLEMS" = "0" ]; then
    ok "no problems found"
    return 0
  fi
  err "$PROBLEMS problem(s) found"
  if [ "$FLAG_FIX" = "0" ] && [ "$FLAG_AGENT" = "0" ]; then
    say "  next: choose '2) deterministic fix' / '7) mini TUI (guided)' / '3) LLM repair' in the menu,"
    say "        or run: dsh-doctor --guide   (guided)   /   dsh-doctor --agent   (LLM)"
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Guided mode — mini TUI (human-in-the-loop). Every finding is shown and every
# fix is confirmed one at a time ([Y]es / [n]o / [?]detail / [q]uit). The LLM
# step is optional and human-gated: skip, read-only review, or explicit
# unattended repair (hard timeout + Ctrl-C). No long unattended phase by
# default — that is the 2026-08-13 lesson.
# ---------------------------------------------------------------------------
guided_fix_desc() {
  case "$1" in
    web)      echo "restart web — kill old listener + nohup dsh web, poll HTTP 200   // 重启 web（杀旧进程+nohup 拉起，轮询 200）" ;;
    launcher) echo "materialize slot bin/dsh + relink self-heal (ab.sh status)      // 补位槽 bin/dsh + relink 自愈" ;;
    relink)   echo "ab.sh status — relink self-heal (rebuilds extension links)      // ab.sh status（重建扩展链接）" ;;
    boot)     echo "materialize current slot's bin/dsh (compiled CLI entry)          // 补位 current 槽的 bin/dsh" ;;
    session)  echo "lossless repair of failing session log(s) (backup + re-frame)    // 无损修复损坏的 session 日志（备份+重排帧）" ;;
    pdep)     echo "plugin dependency self-heal (link missing @deepseek-ai/* pkg)     // 插件依赖自愈（链接缺失的 @deepseek-ai/* 包）" ;;
    llm)      echo "configure DEEPSEEK_API_KEY in ~/.dsh/.env (you paste the key)    // 配置 DEEPSEEK_API_KEY（你粘贴 key）" ;;
    *)        echo "no automatic fix — resolve manually (see hint)                   // 无自动修复 — 请按提示手动处理" ;;
  esac
}

guided_fix() {
  case "$1" in
    web)      restart_web ;;
    launcher) fix_relink_selfheal; fix_launcher ;;
    relink)   fix_relink_selfheal ;;
    boot)     fix_launcher ;;
    session)  fix_sessions ;;
    pdep)     fix_plugin_deps ;;
    llm)      fix_llm_config ;;
    *)        warn "no automatic fix for '$1' — resolve manually"; return 1 ;;
  esac
}

doctor_guided() {
  echo
  echo "=============================================================="
  if [ "$LANG_CODE" = "zh" ]; then
    echo "  dsh web 医生 — mini TUI（引导模式）"
    echo "  你指导、医生执行：每步确认，默认不无人长跑"
  else
    echo "  dsh web Doctor — mini TUI (guided)"
    echo "  you steer, the doctor executes: every step confirmed, no unattended long runs by default"
  fi
  echo "=============================================================="

  # 1. diagnose (read-only)
  doctor_diagnose

  local fixed=0 skipped=0 failed=0 idx=0 entry kind hint answer desc
  if [ "${#PROBLEM_LIST[@]}" -gt 0 ]; then
    echo
    if [ "$LANG_CODE" = "zh" ]; then
      info "发现 ${#PROBLEM_LIST[@]} 个问题 — 逐个确认修复（可跳过）："
    else
      info "${#PROBLEM_LIST[@]} problem(s) — confirm each fix (or skip):"
    fi
    for entry in "${PROBLEM_LIST[@]}"; do
      idx=$((idx + 1))
      kind=${entry%%|*}
      hint=${entry#*|}
      echo
      printf '  [%d/%d] %s\n' "$idx" "${#PROBLEM_LIST[@]}" "$hint"
      desc=$(guided_fix_desc "$kind")
      while true; do
        printf '      %s\n' "$desc"
        printf '      %s' "Apply? [Y]es [n]o [?]detail [q]uit   // 应用？[Y]是 [n]跳过 [?]详情 [q]退出: "
        read -r answer || { answer=q; echo; }
        answer=${answer%$'\r'}
        case "$answer" in
          ""|y|Y) if guided_fix "$kind"; then fixed=$((fixed + 1)); else failed=$((failed + 1)); fi; break ;;
          n|N) warn "  skipped"; skipped=$((skipped + 1)); break ;;
          \?|h|H) printf '      %s\n' "$(guided_fix_desc "$kind")"; continue ;;
          q|Q) echo; info "quitting guided mode (applied fixes stay applied)   // 退出引导（已应用的修复保持生效）"; return 0 ;;
          *) continue ;;
        esac
      done
    done
  else
    ok "no problems found by the deterministic checks"
  fi

  # 2. verify — re-run the diagnosis (honest re-check of what we touched)
  echo
  info "== verify =="
  doctor_diagnose

  # 3. optional LLM step — human-gated
  echo
  if [ "$LANG_CODE" = "zh" ]; then
    echo "  LLM 步骤（可选）—— 让大模型交叉验证确定性检查漏掉的问题？"
    echo "    1) 跳过（确定性已修完并验证）"
    echo "    2) 只读复核（不改任何文件，约 1-2 分钟，随时 Ctrl-C）"
    echo "    3) LLM 复核+修复（可改文件；你旁观推理过程，随时 Ctrl-C）"
    printf "  选择 [1-3]: "
  else
    echo "  LLM step (optional) — let the model cross-check what the deterministic checks missed?"
    echo "    1) Skip (deterministic fixes done & verified)"
    echo "    2) Read-only review (changes nothing, ~1-2 min, Ctrl-C anytime)"
    echo "    3) Review + repair (may modify files; watch the reasoning, Ctrl-C anytime)"
    printf "  choose [1-3]: "
  fi
  read -r llm_choice || llm_choice=1
  llm_choice=${llm_choice%$'\r'}
  case "$llm_choice" in
    2)
      doctor_diagnose >"$REPORT" 2>&1
      run_agent review ;;
    3)
      doctor_diagnose >"$REPORT" 2>&1
      run_agent force ;;
    *) ok "LLM step skipped" ;;
  esac

  # 4. restart gate — only if the web is still down
  if [ "$code" != "200" ]; then
    echo
    if [ "$LANG_CODE" = "zh" ]; then
      printf "  web 仍未起来 — 现在重启 web？[Y/n]: "
    else
      printf "  web is still down — relaunch now? [Y/n]: "
    fi
    read -r rq || rq=y
    rq=${rq%$'\r'}
    case "$rq" in
      ""|y|Y) restart_web || true ;;
      *) warn "skipped relaunch — run later: dsh-doctor --fix --restart" ;;
    esac
  fi

  # 5. summary
  echo
  info "== summary =="
  if [ "$LANG_CODE" = "zh" ]; then
    printf '  修复 %d / 跳过 %d / 失败 %d；当前 web: ' "$fixed" "$skipped" "$failed"
    [ "$code" = "200" ] && echo "✅ 正常" || echo "❌ 未起"
    echo "  下一步：dsh-doctor（菜单）/ dsh-doctor --agent（LLM 深度）/ curl http://127.0.0.1:$PORT/"
  else
    printf '  fixed %d / skipped %d / failed %d; web now: ' "$fixed" "$skipped" "$failed"
    [ "$code" = "200" ] && echo "✅ up" || echo "❌ down"
    echo "  next: dsh-doctor (menu) / dsh-doctor --agent (deep LLM) / curl http://127.0.0.1:$PORT/"
  fi
}

# ---------------------------------------------------------------------------
# doctor_menu — user-first interactive menu (bilingual: EN default, switch in
# the menu or via DSH_DOCTOR_LANG=zh). One glance, no flags to remember.
# ---------------------------------------------------------------------------
menu_status() {
  local code="$1"
  if [ "$LANG_CODE" = "zh" ]; then
    [ "$code" = "200" ] && printf '✅ 正常' || printf '❌ 异常 / 未起'
  else
    [ "$code" = "200" ] && printf '✅ healthy' || printf '❌ down / not responding'
  fi
}

doctor_menu() {
  while true; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null || true); code=${code:-000}
    echo
    echo "=============================================================="
    if [ "$LANG_CODE" = "zh" ]; then
      echo "  dsh web 医生 — 一键救火"
      echo "  当前 web(:$PORT): $(menu_status "$code")"
    else
      echo "  dsh web Doctor — one-shot rescue"
      echo "  web(:$PORT): $(menu_status "$code")"
    fi
    echo "=============================================================="
    if [ "$LANG_CODE" = "zh" ]; then
      echo "  1) 快速体检（只读）   // Quick check (diagnose only)"
      echo "  2) 修复配置问题（机械）// Fix config issues (mechanical, no LLM):"
      echo "                        //   relink/插件依赖/launcher/session/LLM 凭据"
      echo "  3) LLM 修复（推荐）   // LLM repair (recommended): LLM 读诊断+日志"
      echo "                        //   推理根因，发现/修复任意插件问题"
      echo "  4) LLM 深度检测和修复 // Deep LLM check & repair (always runs,"
      echo "                        //   不因全绿跳过)   even when diagnosis is green)"
      echo "  5) mini TUI 引导模式 // Guided: 全屏交互终端——自动修复 + LLM"
      echo "                        //   对话（看完整 CoT，随时 Ctrl-C 打断指引）"
      echo "  6) 切换语言 English   // Switch language"
      echo "  7) 退出               // Exit"
      printf "  选择 [1-7]: "
    else
      echo "  1) Quick check (diagnose only)          // 快速体检（只读）"
      echo "  2) Fix config issues (mechanical)      // 修复配置问题（机械，不依赖 LLM）："
      echo "     incl. relaunch web                  //   relink/插件依赖/launcher/"
      echo "                                          //   session/LLM 凭据等已知配置故障"
      echo "  3) LLM repair (recommended)            // LLM 修复（推荐）：LLM 读诊断+日志"
      echo "                                          //   推理根因，发现/修复任意插件问题"
      echo "  4) Deep LLM check & repair (always)   // LLM 深度检测和修复（每次都跑，"
      echo "                                          //   不因诊断全绿而跳过）"
      echo "  5) Mini TUI (guided)                   // 全屏交互终端：自动修复 + LLM"
      echo "                                          //   对话（看完整 CoT，随时打断指引）"
      echo "  6) Switch language 中文                 // 切换语言"
      echo "  7) Exit                                 // 退出"
      printf "  choose [1-7]: "
    fi
    read -r choice || exit 0
    choice=${choice%$'\r'}   # pty/script input carries CR; strip it
    case "$choice" in
      1) FLAG_FIX=0; FLAG_RESTART=0; FLAG_AGENT=0; FLAG_FORCE=0; FLAG_GUIDE=0; doctor_run ;;
      2) FLAG_FIX=1; FLAG_RESTART=1; FLAG_AGENT=0; FLAG_FORCE=0; FLAG_GUIDE=0; doctor_run ;;
      3) ( FLAG_FIX=0; FLAG_RESTART=0; FLAG_AGENT=1; FLAG_FORCE=0; FLAG_GUIDE=0; exec > >(tee "$REPORT") 2>&1; doctor_run ) ;;
      4) ( FLAG_FIX=0; FLAG_RESTART=0; FLAG_AGENT=1; FLAG_FORCE=1; FLAG_GUIDE=0; exec > >(tee "$REPORT") 2>&1; doctor_run ) ;;
      5) FLAG_GUIDE=1; run_guided ;;
      6) [ "$LANG_CODE" = "zh" ] && LANG_CODE=en || LANG_CODE=zh
         [ "$LANG_CODE" = "zh" ] && echo "  已切换到中文（DSH_DOCTOR_LANG=zh 固定）" || echo "  switched to English (set DSH_DOCTOR_LANG=zh for default Chinese)"
         continue ;;
      7) [ "$LANG_CODE" = "zh" ] && echo "再见" || echo "bye"; exit 0 ;;
      *) [ "$LANG_CODE" = "zh" ] && echo "  无效选择，请输入 1-7" || echo "  invalid choice, enter 1-7"; continue ;;
    esac
    echo
    [ "$LANG_CODE" = "zh" ] && printf "  按回车返回菜单..." || printf "  press Enter to return to the menu..."
    read -r _ || true
  done
}

# --guide: real mini TUI (curses, full-screen, interruptible chat with the
# LLM, markdown rendering) when a terminal + python3+curses are available;
# otherwise fall back to the step-by-step non-TTY guided mode.
#
# UX rule (2026-08-13, 2nd pass): NEVER let the user stare at a blank screen.
# The deterministic diagnosis runs FIRST, streaming into the plain terminal
# (visible progress line by line — same output as `dsh-doctor` alone), the
# problem list is handed to the TUI via a JSON file, and ONLY THEN curses
# takes over for the interactive part (fixes + LLM chat).
run_guided() {
  if [ -t 0 ] && command -v python3 >/dev/null 2>&1 \
     && python3 -c 'import curses' >/dev/null 2>&1; then
    local json_file="${DSH_DOCTOR_PROBLEMS:-/tmp/dsh-doctor-problems.json}"
    # 1. diagnosis streams into the terminal (no black screen)
    echo
    info "diagnosing — output below, then the interactive TUI starts   // 体检中——输出如下，随后进入交互 TUI"
    doctor_diagnose
    # 2. hand the structured problem list to the TUI
    { printf 'WEB=%s\n' "$code"; printf '%s\n' "${PROBLEM_LIST[@]:-}"; } | python3 -c '
import json, sys
lines = sys.stdin.read().splitlines()
web, probs = "000", []
for ln in lines:
    if ln.startswith("WEB="):
        web = ln[4:]
    elif "|" in ln:
        i, h = ln.split("|", 1)
        probs.append({"id": i, "hint": h})
json.dump({"web": web, "count": len(probs), "problems": probs}, open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/dsh-doctor-problems.json", "w"))
' "$json_file"
    echo
    info "diagnosis done — starting the interactive TUI   // 体检完成——进入交互 TUI"
    # the TUI inherits the CURRENT menu language (the menu may have toggled
    # LANG_CODE without changing the DSH_DOCTOR_LANG env var)
    export DSH_DOCTOR_LANG="${LANG_CODE:-en}"
    python3 "$SKILLS_DIR/dsh-web-doctor/scripts/doctor-tui.py" --problems-json "$json_file"
    return $?
  fi
  doctor_guided
}

# --- entry point ---------------------------------------------------------------
# No flags + interactive terminal → menu (the user-first path).
if [ "$FLAG_FIX" = "0" ] && [ "$FLAG_RESTART" = "0" ] && [ "$FLAG_AGENT" = "0" ] && [ "$FLAG_GUIDE" = "0" ] && [ -t 0 ]; then
  doctor_menu
  exit 0
fi

# --diag-json: machine-readable diagnosis for the TUI (web + problem list).
if [ "${FLAG_DIAG_JSON:-0}" = "1" ]; then
  doctor_diagnose >/dev/null 2>&1
  { printf 'WEB=%s\n' "$code"; printf '%s\n' "${PROBLEM_LIST[@]:-}"; } | python3 -c '
import json, sys
lines = sys.stdin.read().splitlines()
web, probs = "000", []
for ln in lines:
    if ln.startswith("WEB="):
        web = ln[4:]
    elif "|" in ln:
        i, h = ln.split("|", 1)
        probs.append({"id": i, "hint": h})
print(json.dumps({"web": web, "count": len(probs), "problems": probs}))
'
  exit 0
fi

# --fix-item <kind>: run ONE fix primitive (used by the TUI; also handy for
# scripts). doctor_diagnose first so CURRENT etc. are set.
if [ -n "${FLAG_FIX_ITEM:-}" ]; then
  doctor_diagnose >/dev/null 2>&1
  guided_fix "$FLAG_FIX_ITEM"
  exit $?
fi


if [ "$FLAG_GUIDE" = "1" ]; then
  run_guided
  exit $?
fi

# --agent: the LLM is the doctor's brain — tee every deterministic check to
# the report file the headless agent will read.
if [ "$FLAG_AGENT" = "1" ]; then
  exec > >(tee "$REPORT") 2>&1
fi

doctor_run
exit $?
