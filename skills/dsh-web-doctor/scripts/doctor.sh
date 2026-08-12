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

FLAG_FIX=0; FLAG_RESTART=0; FLAG_QUIET=0; FLAG_AGENT=0; FLAG_FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FLAG_FORCE=1; shift ;;
    --help|-h)
      cat <<'HELP'
dsh web Doctor — 一键救火（web 挂了 / 起不来时用）

用法（不用记，直接跑 dsh-doctor 就有交互菜单）：
  dsh-doctor                    交互菜单（推荐）
  dsh-doctor --agent            LLM 智能自愈（诊断+找根因+修复+拉起 web）
  dsh-doctor --agent --force     强制 LLM 验收（即使诊断全绿也跑 LLM 交叉验证）
  dsh-doctor --fix --restart    确定性修复 + 拉起 web（不依赖 LLM）
  dsh-doctor --fix              只确定性修复
  dsh-doctor --quiet            少输出

入口（二选一，都行）：
  dsh-doctor                    # PATH 命令（~/.local/bin/dsh-doctor，与 dsh 同目录）
  ~/.dsh/source/current/bin/dsh-doctor   # 槽 bin 内（prepare 后自动保留）
HELP
      exit 0 ;;
    --fix) FLAG_FIX=1; shift ;;
    --restart) FLAG_RESTART=1; shift ;;
    --agent) FLAG_AGENT=1; shift ;;
    --quiet) FLAG_QUIET=1; shift ;;
    *) echo "unknown arg: $1 (try: dsh-doctor --help)" >&2; exit 2 ;;
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
          MISSING:*) err "$line" ;;
          *) say "  $line" ;;
        esac
      done <<< "$relink_out"
    fi
    [ "$rc" = "0" ] || note_problem
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
  PDEPS="$SKILLS_DIR/dsh-web-doctor/scripts/plugin-deps-check.mjs"
  if [ -f "$PDEPS" ]; then
    echo
    say "== profile bundles dependency check =="
    while IFS= read -r line; do
      case "$line" in
        FIXABLE:*) warn "  $line"; note_problem ;;
        MISSING:*) err "  $line"; note_problem ;;
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
      note_problem
    fi
  else
    err "  ~/.dsh/.env missing — no LLM credentials (web/headless cannot call an LLM)"
    note_problem
  fi
  [ -f "$HOME/.dsh/settings.yaml" ] && say "  settings.yaml present" || warn "  settings.yaml missing (non-fatal)"

  # 3h. what happened last (most recently active sessions)
  echo
  say "== last activity in recent sessions =="
  if [ -f "$SKILLS_DIR/dsh-web-doctor/scripts/session-last-activity.mjs" ]; then
    node "$SKILLS_DIR/dsh-web-doctor/scripts/session-last-activity.mjs" --limit 4 2>&1 | sed 's/^/  /'
  fi

  # --- 4. repair ---------------------------------------------------------------
  if [ "$FLAG_FIX" = "1" ]; then
    echo
    info "== auto-fix =="
    if [ "$PROBLEMS" = "0" ]; then
      ok "diagnosis found no problems — skipping repair (no mechanical fix needed)"
    else

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

    # 4d. generic plugin dependency self-heal (any bundle; source auto-found in
    #     the current slot's packages by package name — no ab-config mapping)
    if [ -f "$PDEPS" ]; then
      while IFS= read -r line; do
        case "$line" in
          FIXABLE:*)
            pkg=$(printf '%s' "$line" | sed 's/FIXABLE: \([^ ]*\).*/\1/')
            repo=$(printf '%s' "$line" | sed 's/.*repo=\([^ ]*\).*/\1/')
            src=$(printf '%s' "$line" | sed 's/.*-> //')
            link="$repo/node_modules/$pkg"
            mkdir -p "$(dirname "$link")"
            ln -sfn "$src" "$link"
            ok "  plugin dep self-heal: $link -> $src"
            ;;
        esac
      done < <(node "$PDEPS" 2>&1)
    fi

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
    info "== LLM brain =="
    # All green + web up => the LLM has nothing to fix; don't burn tokens on
    # a healthy system (the report it would read already says so).
    if [ "$PROBLEMS" = "0" ] && [ "$code" = "200" ] && [ "$FLAG_FORCE" != "1" ]; then
      ok "diagnosis is all green and web is UP — LLM brain not needed (use --force to force full LLM acceptance)"
    elif ! command -v dsh >/dev/null 2>&1; then
      err "'dsh' not on PATH — cannot launch the headless agent (fall back to: dsh-doctor --fix --restart)"
      exit 1
    elif ! dsh --profile headless --help >/dev/null 2>&1; then
      err "'dsh --profile headless' unavailable — LLM brain cannot start (fall back to: dsh-doctor --fix --restart)"
      exit 1
    else
    AGENT_TASK=$(cat <<'PROMPT'
你是 dsh web 的 out-of-band 自愈 agent（one-shot）。web（3080）挂了或状态异常，
由你诊断根因、修复、把 web 拉回来。headless 模式下你可用工具读文件/执行命令。

步骤：
0. 先看报告里的 LLM config 段：若 DEEPSEEK_API_KEY 缺失/为空（~/.dsh/.env），
   提示用户补 key（echo 'DEEPSEEK_API_KEY=<key>' >> ~/.dsh/.env），不要臆造凭据；
   key 在则继续。
1. 读 /tmp/dsh-doctor-report.txt —— dsh-doctor 的确定性体检报告
   （web/launcher/relink/槽可启动/session 文件层/web.log 尾部/LLM config/最近活动）。
2. 读 ~/.dsh/skills/dsh-web-doctor/SKILL.md —— 可用修复原语说明。
3. 需要更深入时：node ~/.dsh/skills/dsh-web-doctor/scripts/session-last-activity.mjs
   看最近会话最后发生的事；tail ~/.dsh/source/web.log。
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

约束：你是自愈 agent，web/GUI 可能不可用；只做必要修复，不动用户数据；
不确定的操作先读报告/日志再决定。不要臆造；查不到就明说。
PROMPT
)
    # headless is one-shot: it prints ONLY the final message, so a long
    # self-heal run looks frozen. Give a clear wait notice + a heartbeat,
    # run with full-access permission (the user invoking the doctor IS the
    # self-heal authorization), and an outer timeout so a stuck agent can
    # never hang the user forever.
    ok "launching headless LLM agent (report: $REPORT)"
    say "  watching its live session log below; final answer appears when it finishes (1-3 min typical):"
    # the agent writes its own session log as it works (reasoning chunks,
    # tool calls, generated text) — tail that so the user SEES it working.
    # the web's own session (current chat) is also being written constantly —
    # the agent's session is the NEW one that did not exist before launch.
    before_list=$(find "$HOME/.dsh/sessions" -name session.jsonl.zstd 2>/dev/null)
    ( DSH_PERMISSION_MODE=danger-full-access dsh --profile headless "$AGENT_TASK" 2>&1 | sed 's/^/  [agent] /' ) &
    APID=$!
    waited=0; AGENT_TIMEOUT="${DSH_DOCTOR_AGENT_TIMEOUT:-300}"
    last_pos=0; agent_log=
    while kill -0 "$APID" 2>/dev/null && [ "$waited" -lt "$AGENT_TIMEOUT" ]; do
      sleep 4; waited=$((waited+4))
      # live stream: the headless agent writes its OWN session log as it
      # works — reasoning chain (CoT), tool calls, generated text. Read the
      # NEW lines since the last tick and print their full content, so the
      # user SEES the whole thought process, not a heartbeat.
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
        # reasoning lives in data.texts (an array of tokens) — join them
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
        # one line per event, prefix [llm] so the CoT reads like a stream
        for ln in txt.splitlines():
            if ln.strip():
                print("  [llm] " + ln.strip()[:400])
' 2>/dev/null
          last_pos=$total
        fi
      fi
    done
    if kill -0 "$APID" 2>/dev/null; then
      err "LLM agent timed out after ${waited}s (DSH_DOCTOR_AGENT_TIMEOUT) — it may be stuck; fall back to: dsh-doctor --fix --restart"
      kill "$APID" 2>/dev/null
    else
      wait "$APID" 2>/dev/null || true
      say "  LLM agent finished (~${waited}s)"
    fi
    echo
    info "verify with: dsh-doctor  (or curl http://127.0.0.1:3080/)"
    fi   # end of the "problems found / web down -> run LLM brain" branch
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
# doctor_menu — user-first interactive menu (bilingual: EN default, switch in
# the menu or via DSH_DOCTOR_LANG=zh). One glance, no flags to remember.
# ---------------------------------------------------------------------------
LANG_CODE="${DSH_DOCTOR_LANG:-en}"

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
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)
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
      echo "  5) 退出               // Exit"
      echo "  6) 切换语言 English   // Switch language"
      printf "  选择 [1-6]: "
    else
      echo "  1) Quick check (diagnose only)          // 快速体检（只读）"
      echo "  2) Fix config issues (mechanical)      // 修复配置问题（机械，不依赖 LLM）："
      echo "     incl. relaunch web                  //   relink/插件依赖/launcher/"
      echo "                                          //   session/LLM 凭据等已知配置故障"
      echo "  3) LLM repair (recommended)            // LLM 修复（推荐）：LLM 读诊断+日志"
      echo "                                          //   推理根因，发现/修复任意插件问题"
      echo "  4) Deep LLM check & repair (always)   // LLM 深度检测和修复（每次都跑，"
      echo "                                          //   不因诊断全绿而跳过）"
      echo "  5) Exit                                 // 退出"
      echo "  6) Switch language 中文                 // 切换语言"
      printf "  choose [1-6]: "
    fi
    read -r choice || exit 0
    choice=${choice%$'\r'}   # pty/script input carries CR; strip it
    case "$choice" in
      1) FLAG_FIX=0; FLAG_RESTART=0; FLAG_AGENT=0; FLAG_FORCE=0; doctor_run ;;
      2) FLAG_FIX=1; FLAG_RESTART=1; FLAG_AGENT=0; FLAG_FORCE=0; doctor_run ;;
      3) ( FLAG_FIX=0; FLAG_RESTART=0; FLAG_AGENT=1; FLAG_FORCE=0; exec > >(tee "$REPORT") 2>&1; doctor_run ) ;;
      4) ( FLAG_FIX=0; FLAG_RESTART=0; FLAG_AGENT=1; FLAG_FORCE=1; exec > >(tee "$REPORT") 2>&1; doctor_run ) ;;
      5) [ "$LANG_CODE" = "zh" ] && echo "再见" || echo "bye"; exit 0 ;;
      6) [ "$LANG_CODE" = "zh" ] && LANG_CODE=en || LANG_CODE=zh
         [ "$LANG_CODE" = "zh" ] && echo "  已切换到中文（DSH_DOCTOR_LANG=zh 固定）" || echo "  switched to English (set DSH_DOCTOR_LANG=zh for default Chinese)"
         continue ;;
      *) [ "$LANG_CODE" = "zh" ] && echo "  无效选择，请输入 1-6" || echo "  invalid choice, enter 1-6"; continue ;;
    esac
    echo
    [ "$LANG_CODE" = "zh" ] && printf "  按回车返回菜单..." || printf "  press Enter to return to the menu..."
    read -r _ || true
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
