#!/usr/bin/env bash
# dsh-web-doctor — OUT-OF-BAND diagnosis, repair and relaunch for dsh web.
#
# Use this when the web (3080) is down or won't boot — including when BOTH A/B
# slots are broken — and the normal GUI/agent path is unavailable. It runs
# entirely from the terminal with local tools (node/zstd/jq/curl/ps/lsof) and
# the installed skills' scripts; it does NOT depend on a running web process.
#
# USER-FIRST: run `dsh-doctor` with NO arguments → an interactive menu shows
# the web status and the three things you can do. No flags to remember:
#   1. quick check (read-only)     2. LLM self-heal (recommended)
#   3. deterministic fix + relaunch (no LLM)     4. exit
# Flag mode (for scripts / advanced use) is unchanged:
#   doctor.sh                 # diagnose only (read-only)
#   doctor.sh --fix           # diagnose + deterministic auto-fix
#   doctor.sh --fix --restart # diagnose + fix + relaunch web
#   doctor.sh --agent         # diagnose + LLM brain (headless one-shot)
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
#      slot's compiled packages; if they cannot load, the doctor reports that
#      explicitly and keeps going — L0 conclusions stay authoritative.
#   LLM (--agent): one-shot headless agent (dsh --profile headless) reads the
#      deterministic report + logs, reasons the root cause (adapts to DSH
#      changes), fixes, and relaunches. Headless does NOT load the web's
#      extension bundles (dsh-track etc. are web-profile only), so extension
#      dependency faults do not stop the LLM brain; it DOES load skills
#      (~/.dsh/skills) and depends on the current slot's compiled packages
#      and LLM credentials — when those are broken, --fix (L0) is the fallback.
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

FLAG_FIX=0; FLAG_RESTART=0; FLAG_QUIET=0; FLAG_AGENT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --fix) FLAG_FIX=1; shift ;;
    --restart) FLAG_RESTART=1; shift ;;
    --agent) FLAG_AGENT=1; shift ;;
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

# ---------------------------------------------------------------------------
# doctor_run — one pass: environment → layout → diagnosis → (fix) → (restart)
# → (agent) → report. Flags decide which stages run.
# ---------------------------------------------------------------------------
doctor_run() {
  # --- 1. environment --------------------------------------------------------
  info "dsh-web-doctor (out-of-band) — port $PORT"
  missing=""
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
  [ -n "$CURRENT" ] || { err "no current symlink — the A/B layout is missing"; note_problem; }

  # --- 3. diagnosis ----------------------------------------------------------
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
    # real slot path and the `$DSH_SOURCE/current/...` spelling.
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

  # 3e. session store health — L0 self-contained check FIRST (file layer only:
  # node built-ins + zstd CLI, no DSH compiled packages — works even when the
  # current slot / its build artifacts are broken). The compiled-reader deep
  # check (check-all-sessions) is an OPTIONAL enhancement.
  echo
  say "== session store (file-layer, minimal deps) =="
  L0="$SKILLS_DIR/dsh-web-doctor/scripts/session-store-check.mjs"
  if [ -f "$L0" ]; then
    out=$(node "$L0" 2>&1); rc=$?
    tail_line=$(printf '%s\n' "$out" | tail -1)
    if [ "$rc" = "0" ]; then
      ok "sessions: $tail_line"
    else
      err "sessions: $tail_line"
      note_problem
    fi
  else
    err "session-store-check.mjs missing — session store not checked"
    note_problem
  fi
  if [ -f "$REC/check-all-sessions.mjs" ]; then
    deep=$(node "$REC/check-all-sessions.mjs" 2>&1); drc=$?
    if [ "$drc" = "0" ]; then
      say "  deep check (compiled reader): $(printf '%s\n' "$deep" | tail -1)"
    else
      warn "  deep check unavailable (compiled reader failed to load — current slot may be broken; file-layer check above is authoritative for doctor's purposes)"
    fi
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

    # 4c. unknown session-event repair (ignorable marking) — DEEP layer: needs
    #     the compiled DSH reader; degrades gracefully when it cannot load.
    if [ -f "$REC/repair-unknown-events.mjs" ]; then
      node "$REC/repair-unknown-events.mjs" --all >/tmp/dsh-doctor-repair.log 2>&1
      rc=$?
      if [ "$rc" = "0" ] || [ "$rc" = "2" ]; then
        tail -1 /tmp/dsh-doctor-repair.log | sed 's/^/  /'
        ok "unknown-event repair pass complete"
      else
        err "unknown-event repair could not run (deep layer needs the compiled DSH reader; likely the current slot is broken)."
        err "  diagnose the slot first; the repair itself: node $REC/repair-unknown-events.mjs --all"
        note_problem
      fi
    fi

    # --- 4d. verify fixes (re-check what we just repaired) ---------------------
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

  # --- 5. restart (L0: self-contained kill + nohup + poll; the recovery skill's
  #        restart script is used when present, else doctor does it itself) -----
  if [ "$FLAG_RESTART" = "1" ]; then
    echo
    info "== relaunching dsh web (port $PORT) =="
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then
      ok "web already up — skipping restart"
    else
      if [ -f "$REC/restart-dsh-web.sh" ]; then
        sh "$REC/restart-dsh-web.sh" >/tmp/dsh-doctor-restart.log 2>&1
        say "  restart script: $(tail -2 /tmp/dsh-doctor-restart.log | tr '\n' ' ')"
      else
        say "  restarting with doctor's built-in fallback (no recovery skill present)..."
        local_pids=$(lsof -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null)
        [ -n "$local_pids" ] && kill -TERM $local_pids 2>/dev/null || true
        i=0; while [ "$i" -lt 30 ] && lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; do i=$((i+1)); sleep 1; done
        ( cd "$HOME" && nohup dsh web >/tmp/dsh-web-restart.log 2>&1 & )
      fi
      code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
      if [ "$code" = "200" ]; then
        ok "web is UP on :$PORT after restart"
      else
        err "web NOT up after restart (HTTP $code) — inspect the log tail above"
        exit 2
      fi
    fi
  fi

  # --- 5b. LLM brain (--agent): hand the deterministic report to a one-shot
  #        headless agent. Deterministic rules can't anticipate a changed DSH;
  #        the LLM reads the new symptoms and reasons its way out.
  if [ "$FLAG_AGENT" = "1" ]; then
    echo
    info "== LLM brain: handing the report to a one-shot headless agent =="
    if ! command -v dsh >/dev/null 2>&1; then
      err "'dsh' not on PATH — cannot launch the headless agent (fall back to: dsh-doctor --fix --restart)"
      exit 1
    fi
    if ! dsh --profile headless --help >/dev/null 2>&1; then
      err "'dsh --profile headless' unavailable — LLM brain cannot start (fall back to: dsh-doctor --fix --restart)"
      exit 1
    fi
    AGENT_TASK=$(cat <<'PROMPT'
你是 dsh web 的 out-of-band 自愈 agent（one-shot）。web（3080）挂了或状态异常，
由你诊断根因、修复、把 web 拉回来。headless 模式下你可用工具读文件/执行命令。

步骤：
1. 读 /tmp/dsh-doctor-report.txt —— dsh-doctor 的确定性体检报告
   （web/launcher/relink/槽可启动/session 文件层/web.log 尾部/最近活动）。
2. 读 ~/.dsh/skills/dsh-web-doctor/SKILL.md —— 可用修复原语说明。
3. 需要更深入时：node ~/.dsh/skills/dsh-web-doctor/scripts/session-last-activity.mjs
   看最近会话最后发生的事；tail ~/.dsh/source/web.log。
4. 找根因 → 修复。优先复用确定性原语：
   bash ~/.dsh/skills/dsh-web-doctor/scripts/doctor.sh --fix
   （relink 自愈 / bin/dsh 补位 / 未知事件 ignorable / 损坏日志修复）；
   也可直接执行修复命令（如 ln -sfn 重建扩展链接）。
5. 验证：curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3080/ 应为 200；
   若 web 未起，用 restart-dsh-web.sh 或 nohup dsh web 拉起。
6. 最终输出（简洁中文）：根因一句话、做了什么、当前 web 状态；
   若无法修复：卡在哪一步、缺什么、需要用户做什么。

约束：你是自愈 agent，web/GUI 可能不可用；只做必要修复，不动用户数据；
不确定的操作先读报告/日志再决定。不要臆造；查不到就明说。
PROMPT
)
    ok "launching: dsh --profile headless <self-heal task> (report: $REPORT)"
    dsh --profile headless "$AGENT_TASK" 2>&1 | sed 's/^/  [agent] /'
    echo
    info "LLM brain finished — verify with: dsh-doctor  (or curl http://127.0.0.1:3080/)"
  fi

  # --- 6. report ---------------------------------------------------------------
  echo
  info "== report =="
  if [ "$PROBLEMS" = "0" ]; then
    ok "no problems found"
  else
    err "$PROBLEMS problem(s) found"
    if [ "$FLAG_FIX" = "0" ] && [ "$FLAG_AGENT" = "0" ]; then
      say "  next: choose '2) LLM self-heal' or '3) deterministic fix + relaunch' in the menu,"
      say "        or run: dsh-doctor --agent   (LLM)   /   dsh-doctor --fix --restart   (no LLM)"
    fi
  fi
}

# ---------------------------------------------------------------------------
# doctor_menu — user-first interactive menu. One glance, no flags to remember.
# ---------------------------------------------------------------------------
doctor_menu() {
  while true; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
    echo
    echo "=============================================================="
    echo "  dsh web Doctor — 一键救火"
    echo "  当前 web(:$PORT): $([ "$code" = "200" ] && printf '✅ 正常' || printf '❌ 异常 / 未起')"
    echo "=============================================================="
    echo "  1) 快速体检（只读，几秒）        — 看系统哪里有问题"
    echo "  2) LLM 智能自愈（推荐）          — 自动诊断+找根因+修复+拉起 web"
    echo "  3) 确定性修复+拉起（不依赖 LLM） — 规则保底，web 挂得再彻底也能跑"
    echo "  4) 退出"
    printf "  选择 [1-4]: "
    read -r choice || exit 0
    case "$choice" in
      1) FLAG_FIX=0; FLAG_RESTART=0; FLAG_AGENT=0; doctor_run ;;
      2) ( FLAG_FIX=0; FLAG_RESTART=0; FLAG_AGENT=1; exec > >(tee "$REPORT") 2>&1; doctor_run ) ;;
      3) FLAG_FIX=1; FLAG_RESTART=1; FLAG_AGENT=0; doctor_run ;;
      4) echo "bye"; exit 0 ;;
      *) echo "  无效选择，请输入 1-4"; continue ;;
    esac
    echo
    printf "  按回车返回菜单..."; read -r _ || true
  done
}

# --- entry point ---------------------------------------------------------------
# No flags + interactive terminal → menu (the user-first path).
if [ "$FLAG_FIX" = "0" ] && [ "$FLAG_RESTART" = "0" ] && [ "$FLAG_AGENT" = "0" ] && [ -t 0 ]; then
  doctor_menu
  exit 0
fi

# --agent: the LLM is the doctor's brain — tee every deterministic check to
# the report file the headless agent will read.
if [ "$FLAG_AGENT" = "1" ]; then
  exec > >(tee "$REPORT") 2>&1
fi

doctor_run
exit $?
