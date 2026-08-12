#!/usr/bin/env bash
# common.sh — shared helpers for the DSH A/B snapshot rotation (dsh-snapshot-ab).
# Sourced by ab.sh. No side effects on source; read-only resolution + JSON state.
set -euo pipefail

# ---- logging ----------------------------------------------------------------

ab_log()  { printf '\033[1;34m[ab]\033[0m %s\n' "$*"; }
ab_ok()   { printf '\033[1;32m[ab]\033[0m %s\n' "$*"; }
ab_warn() { printf '\033[1;33m[ab]\033[0m %s\n' "$*" >&2; }
ab_err()  { printf '\033[1;31m[ab]\033[0m %s\n' "$*" >&2; }
ab_die()  { ab_err "$*"; exit 1; }

ab_require() { command -v "$1" >/dev/null 2>&1 || ab_die "missing required tool: $1"; }

# ---- path resolution (follows dsh-customize conventions) --------------------

resolve_link() { # resolve one symlink chain, no readlink -f (not on every macOS)
  local script="$1" target dir
  while [ -L "$script" ]; do
    target=$(readlink "$script")
    case "$target" in
      /*) script="$target" ;;
      *)  dir=$(dirname "$script"); script="$dir/$target" ;;
    esac
  done
  printf '%s\n' "$script"
}

ab_resolve_layout() {
  # Returns (via globals): AB_LAUNCHER, AB_CURRENT (resolved checkout root),
  # AB_SOURCE (container dir holding current + slots), AB_MAIN (main clone).
  local launcher bin resolved root git_common
  launcher=$(command -v dsh || true)
  AB_LAUNCHER="$launcher"
  if [ -n "$launcher" ] && [ -x "$launcher" ]; then
    resolved=$(resolve_link "$launcher")
    root=$(CDPATH='' cd -- "$(dirname -- "$resolved")/.." 2>/dev/null && pwd || true)
  fi
  if [ -z "${root:-}" ] || { [ ! -d "${root:-}/bin" ] && [ ! -f "${root:-}/apps/cli/src/bin.ts" ]; }; then
    # fallback: conventional home layout (20260811+ dropped bin/dsh; the
    # tsx source entry apps/cli/src/bin.ts is the bootable artifact)
    root="$HOME/.dsh/source/current"
    { [ -d "$root/bin" ] || [ -f "$root/apps/cli/src/bin.ts" ]; } || ab_die "cannot resolve DSH source checkout (launcher '$launcher' -> '$root')"
    ab_warn "launcher resolution failed; fell back to $root"
  fi
  AB_CURRENT="$(CDPATH='' cd -- "$root" && pwd)"
  AB_SOURCE="$(CDPATH='' cd -- "$(dirname -- "$AB_CURRENT")" && pwd)"
  git_common=$(git -C "$AB_CURRENT" rev-parse --git-common-dir 2>/dev/null || true)
  if [ -n "$git_common" ]; then
    case "$git_common" in
      /*) AB_MAIN="$git_common" ;;
      *)  AB_MAIN="$(CDPATH='' cd -- "$AB_CURRENT/$git_common" && pwd)" ;;
    esac
    AB_MAIN="$(dirname -- "$AB_MAIN")"
    # physical resolution (symlinked home): Git reports resolved paths
    AB_MAIN="$(cd -- "$AB_MAIN" && pwd -P)"
  else
    AB_MAIN=""
  fi
  AB_STATE_FILE="${AB_STATE_FILE:-$AB_SOURCE/ab-state.json}"
  AB_CONFIG_FILE="${AB_CONFIG_FILE:-$AB_SOURCE/ab-config.json}"
  AB_LOCK_FILE="$AB_SOURCE/.ab.lock"
  AB_LOCK_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lock.py"
}

# ---- state/config (JSON via jq) --------------------------------------------

ab_state_defaults() {
  jq -n --arg source "$AB_SOURCE" --arg main "${AB_MAIN:-}" \
    '{ version: 1,
       source: $source,
       mainClone: $main,
       slots: {
         a: { dir: ($source + "/slot-a"), branch: "dsh-ab/a", snapshot: null, tip: null },
         b: { dir: ($source + "/slot-b"), branch: "dsh-ab/b", snapshot: null, tip: null }
       },
       current: null, confirmed: true, phase: "idle",
       candidate: null, candidateSnapshot: null, lastSwitch: null,
       history: [] }'
}

ab_load_state() {
  if [ -f "$AB_STATE_FILE" ]; then
    AB_STATE=$(jq -c . "$AB_STATE_FILE") || ab_die "corrupt state file $AB_STATE_FILE"
  else
    AB_STATE=$(ab_state_defaults)
  fi
}

ab_save_state() { printf '%s\n' "$AB_STATE" | jq . > "$AB_STATE_FILE"; }

ab_state_get()  { printf '%s\n' "$AB_STATE" | jq -r "$1"; }
ab_state_set()  { AB_STATE=$(printf '%s\n' "$AB_STATE" | jq "$@"); }

ab_load_config() {
  if [ -f "$AB_CONFIG_FILE" ]; then
    AB_CONFIG=$(jq -c . "$AB_CONFIG_FILE") || ab_die "corrupt config file $AB_CONFIG_FILE"
  else
    AB_CONFIG='{}'
  fi
}

ab_config_get() { printf '%s\n' "$AB_CONFIG" | jq -r "$1"; }
# compact per-element output for iterating arrays of objects
ab_config_items() { printf '%s\n' "$AB_CONFIG" | jq -c "$1"; }

# ---- lock -------------------------------------------------------------------

ab_lock() {
  local holder="${1:-$$}"
  python3 "$AB_LOCK_PY" --lock "$AB_LOCK_FILE" "$holder"
}
ab_unlock() { python3 "$AB_LOCK_PY" --unlock "$AB_LOCK_FILE" || true; }

# ---- git helpers ------------------------------------------------------------

ab_snapshot_refs() { # newest-first snapshot branch refs from the main clone
  git -C "$AB_MAIN" for-each-ref --sort=-refname --format='%(refname)' refs/remotes/origin/snapshots/
}

ab_snapshot_branch() { # refs/remotes/origin/snapshots/X -> snapshots/X
  printf '%s\n' "$1" | sed 's#^refs/remotes/origin/##'
}

ab_slot_dir()      { local s="$1"; [ -n "$s" ] || { printf ''; return; }; ab_state_get ".slots.$s.dir"; }
ab_slot_snapshot() { local s="$1"; [ -n "$s" ] || { printf ''; return; }; ab_state_get ".slots.$s.snapshot // \"\""; }
ab_slot_tip()      { local s="$1"; [ -n "$s" ] || { printf ''; return; }; ab_state_get ".slots.$s.tip // \"\""; }

ab_current_slot()  { ab_state_get ".current // \"\""; }
ab_current_dir()   {
  local s; s=$(ab_current_slot)
  [ -n "$s" ] && printf '%s\n' "$(ab_slot_dir "$s")" || printf '%s\n' "$AB_CURRENT"
}

# the slot NOT currently serving (the candidate/rollback slot)
ab_other_slot() {
  local cur; cur=$(ab_current_slot)
  case "$cur" in a) printf 'b\n';; b) printf 'a\n';; *) printf 'a\n';; esac
}

ab_is_initialized() { [ "$(ab_state_get '.current // ""')" != "" ]; }

# ab_boot_cmd <dir> — command line that boots this slot's dsh CLI in the SAME
# way production runs it. Order matters:
#   1. bin/dsh        — the launcher chain (~/.local/bin/dsh -> current/bin/dsh)
#                       uses it; 0810-era slots ship it (a tsx wrapper).
#   2. apps/cli/lib/bin.js — 20260811+ removed bin/dsh; production runs the
#                       COMPILED CLI entry (pure node ESM, no tsconfig paths,
#                       no tsx). Booting a candidate through tsx instead hides
#                       runtime resolution gaps: tsx applies tsconfig paths, so
#                       an extension dep that is missing from node_modules (but
#                       present in the slot's packages or via paths) passes the
#                       smoke test and then kills the real server with
#                       ERR_MODULE_NOT_FOUND (2026-08-11 dsh-llm incident).
#   3. tsx source     — last resort only when nothing was built.
# Callers expand it UNQUOTED inside their subshell (paths contain no spaces).
ab_boot_cmd() {
  local dir="$1"
  if [ -x "$dir/bin/dsh" ]; then
    printf '%s\n' "$dir/bin/dsh"
  elif [ -x "$dir/apps/cli/lib/bin.js" ]; then
    printf '%s\n' "$dir/apps/cli/lib/bin.js"
  else
    printf 'env NODE_USE_ENV_PROXY=1 TSX_TSCONFIG_PATH=%s/tsconfig.json node --import %s/node_modules/tsx/dist/esm/index.mjs %s/apps/cli/src/bin.ts\n' "$dir" "$dir" "$dir"
  fi
}

# ab_slot_usable <dir> — true when the slot has a bootable CLI: bin/dsh
# (0810-era), the compiled CLI entry (20260811+), or the tsx source entry.
ab_slot_usable() {
  [ -x "$1/bin/dsh" ] || [ -x "$1/apps/cli/lib/bin.js" ] || [ -f "$1/apps/cli/src/bin.ts" ]
}

# ab_ensure_slot_launcher <dir> — 20260811+ snapshots removed bin/dsh from the
# tree; the launcher chain (~/.local/bin/dsh -> current/bin/dsh) then breaks
# after a cutover ("dsh: command not found", 2026-08-11). Materialize a
# slot-local bin/dsh wrapper that boots the compiled CLI entry, so the chain
# stays valid on every slot. Idempotent; call after building a slot.
ab_ensure_slot_launcher() {
  local dir="$1"
  [ -x "$dir/bin/dsh" ] && return 0
  [ -x "$dir/apps/cli/lib/bin.js" ] || return 0
  mkdir -p "$dir/bin"
  cat > "$dir/bin/dsh" <<'EOF'
#!/bin/sh
# slot launcher for snapshots without bin/dsh (20260811+): boots the compiled
# CLI entry apps/cli/lib/bin.js (production node ESM). Managed by ab.sh
# (ab_ensure_slot_launcher); do not edit — it is regenerated on prepare.
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
EOF
  chmod +x "$dir/bin/dsh"
  ab_log "  slot launcher -> $dir/bin/dsh (compiled CLI entry)"
}

# ---- misc -------------------------------------------------------------------

ab_now() { date -u +%Y%m%dT%H%M%SZ; }

ab_git_clean() { # "$1" dir → true if no tracked modifications
  [ -z "$(git -C "$1" status --porcelain 2>/dev/null)" ]
}

# ab_detect_web — list every running dsh web instance as "pid port" lines.
# A second instance shares ~/.dsh (sessions/storages) with the production one;
# booting one is only safe for short read-only inspection. Port defaults 3080.
# Matches both launch styles: tsx source (apps/cli/src/bin.ts web) and the
# compiled CLI (apps/cli/lib/bin.js web, 20260811+ production entry).
# NB: avoid `grep | head` pipelines here — under `set -o pipefail` head's early
# close SIGPIPEs grep and the command substitution fails (set -e aborts).
ab_detect_web() {
  local line pid port
  ps aux | grep -E '[b]in\.ts web|apps/cli/[l]ib/bin\.js web' | while IFS= read -r line; do
    [ -n "$line" ] || continue
    pid=$(printf '%s\n' "$line" | awk '{print $2}')
    port=$(printf '%s\n' "$line" | sed -n 's/.*--port \([0-9][0-9]*\).*/\1/p')
    [ -n "$port" ] || port=3080
    printf '%s %s\n' "$pid" "$port"
  done
}

# ab_warn_coexistence — warn that a dsh web instance is already running; the
# caller decides whether to refuse/confirm. Returns 1 if ANY instance runs.
ab_warn_coexistence() {
  local found=0 pid2 port2
  while read -r pid2 port2; do
    [ -n "$pid2" ] || continue
    found=1
    ab_warn "  running dsh web instance: pid $pid2 on port $port2 (shares ~/.dsh sessions/storages — second instance is READ-ONLY inspection only)"
  done < <(ab_detect_web)
  [ "$found" = "1" ]
}
