#!/usr/bin/env bash
# ab.sh — DSH A/B snapshot rotation.
#
# Two slots (a/b) under $DSH_HOME/source hold two versions of the harness.
# Exactly one is `current` (the launcher target); the other holds the previous
# version as rollback and is recycled for the next daily upstream snapshot.
# Cutover is one atomic `ln -sfn current <slot>` + a web restart.
#
# Commands:
#   status                       print layout, slots, phase, running server
#   discover [--json]            fetch upstream, list snapshot branches, diff
#                                stat + official changelog (added agent notes)
#   notes [--from <ref>] [--to <ref>] [--full] [--json]
#                                official changelog between two snapshots: the
#                                agent notes (.agents/notes/implemented) added
#                                in between (defaults: running tip -> newest)
#   init [--yes]                 adopt the running version as slot-a (no restart)
#   prepare [--slot a|b] [--snapshot <ref>] [--skip-web] [--keep] [--force]
#                                build+verify the next snapshot in the other slot
#   verify [--slot a|b]          re-run acceptance on the prepared candidate
#   e2e [--slot a|b] [--port N]   real-browser acceptance: boot candidate on a
#                                staging port and verify configured client
#                                plugins' UI is attached (acceptance.e2e.checks);
#                                mode=auto switch requires this to pass
#   stage --slot a|b [--port N] [--keep] [--yes]
#                                boot ONE slot on a staging port while production
#                                runs (second instance = read-only; detected and
#                                requires --yes when another web is running)
#   switch [--yes]               cut over current -> candidate (restarts web!)
#   confirm                      mark current as confirmed stable (unlocks recycle)
#   rollback [--yes]             restore the previous version (restarts web!)
#   cleanup [--yes] [dir...]     list / remove stale worktrees
#   help
#
# Env: AB_STATE_FILE / AB_CONFIG_FILE override locations; AB_APPROVED=1 is
# equivalent to --yes (used by agents acting on explicit user approval).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/extension.sh
. "$SCRIPT_DIR/lib/extension.sh"
# shellcheck source=lib/acceptance.sh
. "$SCRIPT_DIR/lib/acceptance.sh"

CMD="${1:-help}"
shift || true

FLAG_SLOT=""; FLAG_SNAPSHOT=""; FLAG_PORT=""; FLAG_SKIP_WEB=0; FLAG_KEEP=0; FLAG_FORCE=0; FLAG_YES=0; FLAG_JSON=0
FLAG_FROM=""; FLAG_TO=""; FLAG_FULL=0; FLAG_SOURCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) FLAG_SLOT="${2:-}"; shift 2 ;;
    --snapshot) FLAG_SNAPSHOT="${2:-}"; shift 2 ;;
    --port) FLAG_PORT="${2:-}"; shift 2 ;;
    --from) FLAG_FROM="${2:-}"; shift 2 ;;
    --to) FLAG_TO="${2:-}"; shift 2 ;;
    --source) FLAG_SOURCE=1; shift ;;          # npm 形态之外的手动源码路径
    --skip-web) FLAG_SKIP_WEB=1; shift ;;
    --keep) FLAG_KEEP=1; shift ;;
    --force) FLAG_FORCE=1; shift ;;
    --yes) FLAG_YES=1; shift ;;
    --full) FLAG_FULL=1; shift ;;
    --json) FLAG_JSON=1; shift ;;
    *) ab_die "unknown argument: $1 (see: ab.sh help)" ;;
  esac
done
[ "${AB_APPROVED:-0}" = "1" ] && FLAG_YES=1

# ---- resolution + state load (every command) --------------------------------
ab_resolve_layout
ab_load_state
ab_load_config

# ---- subcommands ------------------------------------------------------------

cmd_status() {
  ab_verify_relinks
  local cur s slot dir snap tip phase confirmed
  cur=$(ab_current_slot)
  phase=$(ab_state_get '.phase // "idle"')
  confirmed=$(ab_state_get '.confirmed')
  ab_log "launcher:  ${AB_LAUNCHER:-<none>}"
  ab_log "current:   $AB_CURRENT  (symlink -> $(readlink "$AB_SOURCE/current" 2>/dev/null || echo '<none>'))"
  ab_log "source:    $AB_SOURCE"
  ab_log "mainClone: ${AB_MAIN:-<unknown>}"
  for s in a b; do
    dir=$(ab_slot_dir "$s"); snap=$(ab_slot_snapshot "$s"); tip=$(ab_slot_tip "$s")
    mark=" "; [ "$cur" = "$s" ] && mark="*"
    ab_log "slot $s$mark: $dir"
    ab_log "        snapshot: ${snap:-<empty>}  tip: ${tip:-<empty>}"
  done
  ab_log "phase: $phase  current-slot: ${cur:-<unset>}  confirmed: $confirmed"
  local wp
  wp=$(ps aux | grep -E '[b]in\.ts web|apps/cli/[l]ib/bin\.js web' | head -2 | awk '{print $2, $9, $11, $12, $13}' | tr '\n' '; ')
  ab_log "running web: ${wp:-<none>}"
  if [ -f "$AB_CONFIG_FILE" ]; then
    ab_log "extensions:"
    local _e name repo dirty
    while read -r _e; do
      [ -n "$_e" ] || continue
      name=$(printf '%s' "$_e" | jq -r '.name'); repo=$(printf '%s' "$_e" | jq -r '.repo')
      dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      ab_log "  $name ($repo) dirty-files: $dirty"
    done < <(ab_config_items '.extensions // [] | .[]')
  fi
  if [ "$FLAG_JSON" = "1" ]; then printf '%s\n' "$AB_STATE" | jq .; fi
}

cmd_discover() {
  # --source: legacy git-snapshot discovery (private snapshot branches / master).
  if [ "$FLAG_SOURCE" = "1" ]; then
    cmd_discover_source
    return 0
  fi
  # Default: npm dist-tag is the upstream truth (2026-08-14+).
  local pkg tag cur_ver newest_ver newest_at
  pkg=$(ab_npm_pkg); tag=$(ab_npm_dist_tag)
  ab_log "checking npm dist-tag $pkg@$tag ..."
  newest_ver=$(ab_npm_version "$tag")
  [ -n "$newest_ver" ] || ab_die "cannot resolve npm dist-tag $tag for $pkg (registry unreachable?)"
  newest_at=$(ab_npm_published_at "$newest_ver")
  ab_log "upstream npm $pkg@$tag: $newest_ver (published ${newest_at:-?})"
  cur_ver=$(ab_slot_version "$(ab_current_slot)")
  ab_log "current slot version: ${cur_ver:-<none>}"
  if [ -n "$cur_ver" ] && [ "$cur_ver" != "$newest_ver" ]; then
    ab_log "next candidate: $newest_ver (current $cur_ver)"
  elif [ -n "$cur_ver" ] && [ "$cur_ver" = "$newest_ver" ]; then
    ab_log "no new npm version beyond the current slot (up to date)"
  else
    ab_log "next candidate: $newest_ver (current slot has no recorded version)"
  fi
  if [ "$FLAG_JSON" = "1" ]; then
    printf '{"package":"%s","distTag":"%s","version":"%s","publishedAt":"%s","current":"%s"}\n' \
      "$pkg" "$tag" "$newest_ver" "${newest_at:-}" "${cur_ver:-}"
  fi
}

# cmd_discover_source — legacy git-based discovery (snapshots/* or master),
# reachable via `ab.sh discover --source`; kept for manual source-slot rotation.
cmd_discover_source() {
  [ -n "$AB_MAIN" ] || ab_die "no main clone resolved"
  local upstream; upstream=$(ab_config_get '.upstream // "origin"')
  ab_log "fetching upstream ($upstream)..."
  git -C "$AB_MAIN" fetch origin 2>&1 | tail -2 || ab_warn "fetch had issues (see above)"
  local refs newest cur_snap
  refs=$(ab_snapshot_refs)
  [ -n "$refs" ] || ab_die "no snapshots/* branches found upstream"
  newest=$(printf '%s\n' "$refs" | head -1 || true)
  ab_log "upstream snapshot branches (newest first):"
  printf '%s\n' "$refs" | while read -r r; do printf '  %s\n' "$(ab_snapshot_branch "$r")"; done
  cur_snap=$(ab_slot_snapshot "$(ab_current_slot)")
  ab_log "current slot snapshot: ${cur_snap:-<none>}"
  local cand=""
  while read -r r; do
    b=$(ab_snapshot_branch "$r")
    if [ "$b" != "$cur_snap" ] && [ "$b" != "$(ab_slot_snapshot "$(ab_other_slot)")" ]; then cand="$r"; break; fi
  done <<< "$refs"
  if [ -n "$cand" ]; then
    ab_log "next candidate: $(ab_snapshot_branch "$cand")"
    if [ -n "$cur_snap" ]; then
      local from to
      from=$(ab_slot_tip "$(ab_current_slot)")
      to=$(git -C "$AB_MAIN" rev-parse "$cand")
      if [ -n "$from" ]; then
        ab_log "diff stat vs current (${from:0:8} -> ${to:0:8}):" \
          && git -C "$AB_MAIN" diff --stat "$from" "$to" | tail -15
        # the notes changelog only reads forward; show it for the normal daily
        # case (candidate NEWER than current), not for an older leftover
        local cand_ts cur_ts
        cand_ts=$(printf '%s' "$(ab_snapshot_branch "$cand")" | sed -E 's/.*([0-9]{8}T[0-9]{6}Z).*/\1/')
        cur_ts=$(printf '%s' "$cur_snap" | sed -E 's/.*([0-9]{8}T[0-9]{6}Z).*/\1/')
        if [ -n "$cand_ts" ] && [ -n "$cur_ts" ] && [ "$cand_ts" \> "$cur_ts" ]; then
          ab_log "official changelog (added agent notes) ${from:0:8} -> ${to:0:8}:"
          ab_notes_changelog "$from" "$to" 0
        fi
      fi
    fi
  else
    ab_log "no new snapshot beyond the two slots (up to date)"
  fi
  if [ "$FLAG_JSON" = "1" ]; then printf '%s\n' "$refs" | sed 's#^refs/remotes/origin/##' | jq -R . | jq -s .; fi
}

# ab_note_key — normalize an agent-note path to its canonical English .md key so
# the .md/.zh.md/.i18n.yaml triplet dedupes to one entry.
ab_note_key() { sed -E 's/\.(zh\.md|i18n\.yaml|md)$//' | awk '{ print $0 ".md" }' | sort -u; }

# ab_resolve_snapshot_ref <ref> — resolve a bare snapshot branch name
# (snapshots/X, no origin/ prefix) or any existing ref/sha to an existing ref;
# prints the ref or fails (exit 1).
ab_resolve_snapshot_ref() {
  local r="$1"
  if git -C "$AB_MAIN" rev-parse --verify "$r^{commit}" >/dev/null 2>&1; then printf '%s\n' "$r"; return 0; fi
  if git -C "$AB_MAIN" rev-parse --verify "refs/remotes/origin/$r^{commit}" >/dev/null 2>&1; then printf 'refs/remotes/origin/%s\n' "$r"; return 0; fi
  return 1
}

# ab_notes_changelog <from> <to> [full] — official changelog between two
# snapshots: the agent notes added in between. The official repo REQUIRES one
# Agent Note per non-trivial change (`.agents/notes/implemented/<class>/
# yyyy-mm-dd-<topic>.md` + .zh.md + .i18n.yaml, each with Problem/Decision/
# Consequences/Alternatives), so the notes ADDED between two snapshots are the
# official changelog for that pair. Triplets are deduped to the English .md.
ab_notes_changelog() {
  local from="$1" to="$2" full="${3:-0}"
  [ -n "$from" ] && [ -n "$to" ] || ab_die "notes: need both from and to"
  local keys mods dels props rejs
  keys=$(git -C "$AB_MAIN" diff --name-only --diff-filter=A "$from" "$to" -- .agents/notes/implemented 2>/dev/null | ab_note_key) || true
  mods=$(git -C "$AB_MAIN" diff --name-only --diff-filter=M "$from" "$to" -- .agents/notes/implemented 2>/dev/null | ab_note_key | wc -l | tr -d ' ') || true
  dels=$(git -C "$AB_MAIN" diff --name-only --diff-filter=D "$from" "$to" -- .agents/notes/implemented 2>/dev/null | ab_note_key | wc -l | tr -d ' ') || true
  props=$(git -C "$AB_MAIN" diff --name-only --diff-filter=A "$from" "$to" -- .agents/notes/proposed 2>/dev/null | ab_note_key | wc -l | tr -d ' ') || true
  rejs=$(git -C "$AB_MAIN" diff --name-only --diff-filter=A "$from" "$to" -- .agents/notes/rejected 2>/dev/null | ab_note_key | wc -l | tr -d ' ') || true
  local n=0 key cls date_title title
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    n=$((n+1))
    cls=$(printf '%s' "$key" | sed -E 's#\.agents/notes/implemented/([^/]+)/.*#\1#')
    date_title=$(printf '%s' "$key" | sed -E 's#.*/([0-9]{4}-[0-9]{2}-[0-9]{2}-[^/]+)\.md$#\1#')
    title=$(git -C "$AB_MAIN" show "$to:$key" 2>/dev/null | sed -n '1s/^# Agent Note: //p') || true
    ab_log "  $cls  $date_title${title:+  —  $title}"
    if [ "$full" = "1" ]; then
      git -C "$AB_MAIN" show "$to:$key" 2>/dev/null | sed 's/^/       /' || true
    fi
  done <<< "$keys"
  ab_log "notes added: $n, modified: $mods, removed: $dels (implemented); proposed +$props, rejected +$rejs"
}

cmd_notes() {
  # Official changelog between two snapshots (defaults: running tip -> newest).
  [ -n "$AB_MAIN" ] || ab_die "no main clone resolved"
  git -C "$AB_MAIN" fetch origin 2>&1 | tail -1 || true
  local from to newest cur_snap cur_tip other_tip from_def=0 to_def=0 to_name
  from="$FLAG_FROM"; to="$FLAG_TO"
  newest=$(ab_snapshot_refs | head -1 || true)
  [ -n "$newest" ] || ab_die "no upstream snapshot branches"
  cur_snap=$(ab_slot_snapshot "$(ab_current_slot)")
  cur_tip=$(ab_slot_tip "$(ab_current_slot)")
  other_tip=$(ab_slot_tip "$(ab_other_slot)")
  if [ -z "$to" ]; then to="$newest"; to_def=1; fi  # full ref (refs/remotes/origin/snapshots/...)
  if [ -z "$from" ]; then
    from_def=1
    if [ -n "$cur_tip" ]; then from="$cur_tip"; else from=$(ab_snapshot_refs | tail -1 || true); fi
  fi
  to_name=$(ab_snapshot_branch "$to")
  # no new snapshot beyond the running one: show the running pair instead
  # (older/other slot -> current), oldest-first like the diff stat.
  if [ "$to_def" = "1" ] && [ "$from_def" = "1" ] && [ "$to_name" = "$cur_snap" ] && [ -n "$other_tip" ]; then
    ab_warn "newest snapshot is the running version — showing the running pair (override with --from/--to)"
    from="$other_tip"; to="$cur_tip"; to_name=$(ab_snapshot_branch "$to")
  fi
  # resolve bare snapshot branch names (snapshots/X -> refs/remotes/origin/snapshots/X),
  # then normalize everything to shas so display/diff/json stay consistent
  from=$(ab_resolve_snapshot_ref "$from") || ab_die "unknown from ref: $from"
  to=$(ab_resolve_snapshot_ref "$to") || ab_die "unknown to ref: $to"
  from=$(git -C "$AB_MAIN" rev-parse "$from^{commit}")
  to=$(git -C "$AB_MAIN" rev-parse "$to^{commit}")
  if [ "$FLAG_JSON" = "1" ]; then
    local keys
    keys=$(git -C "$AB_MAIN" diff --name-only --diff-filter=A "$from" "$to" -- .agents/notes/implemented 2>/dev/null | ab_note_key) || true
    jq -n --arg from "$from" --arg to "$to" \
      --argjson added "$(printf '%s' "$keys" | jq -R -s 'split("\n") | map(select(length > 0))')" \
      '{ from: $from, to: $to, added: $added }'
    return 0
  fi
  ab_log "official changelog (agent notes) ${from:0:8} -> ${to:0:8}:"
  ab_notes_changelog "$from" "$to" "$FLAG_FULL"
}

cmd_init() {
  [ "$FLAG_YES" = "1" ] || ab_die "init repoints the current symlink — pass --yes (agent: obtain explicit user approval first)"
  if ab_is_initialized; then ab_warn "already initialized (current-slot=$(ab_current_slot)); nothing to do"; return 0; fi
  [ -n "$AB_MAIN" ] || ab_die "no main clone resolved"
  local tip branch dir
  tip=$(git -C "$AB_CURRENT" rev-parse HEAD)
  branch=$(git -C "$AB_CURRENT" branch --show-current 2>/dev/null || echo detached)
  dir=$(ab_slot_dir a)
  ab_log "adopting running version as slot-a"
  ab_log "  current tip: $tip (branch $branch)"
  if [ -d "$dir/.git" ] || git -C "$AB_MAIN" worktree list --porcelain 2>/dev/null | grep -q "worktree $dir"; then
    ab_log "  slot-a worktree already exists at $dir — reusing"
  else
    ab_log "  git worktree add -B dsh-ab/a $dir $tip"
    git -C "$AB_MAIN" worktree add -B dsh-ab/a "$dir" "$tip"
  fi
  ab_log "  installing deps in slot-a (so the launcher keeps working after repoint)"
  acc_install "$dir"
  # A fresh worktree has NO build artifacts (lib/ + apps/web/dist are gitignored):
  # dsh web serves the built frontend and the extension typechecks against built
  # lib, so the adopted slot must be fully built before it can take over.
  ab_log "  building slot-a (build:lib + build:web — dsh web needs these; takes a few minutes)"
  if ! acc_build "$dir" 0; then
    ab_warn "slot-a build FAILED — leaving current untouched; fix the build and re-run init"
    exit 1
  fi
  local prev_target
  prev_target=$(readlink "$AB_SOURCE/current" 2>/dev/null || echo "$AB_CURRENT")
  ab_log "  repointing current -> $dir (running server keeps its loaded code; no restart)"
  ln -sfn "$dir" "$AB_SOURCE/current"
  [ "$(readlink "$AB_SOURCE/current")" = "$dir" ] || ab_die "current symlink repoint failed"
  ab_state_set --arg dir "$dir" --arg tip "$tip" --arg branch "$branch" --arg at "$(ab_now)" --arg prev "$prev_target" '
    .slots.a.dir = $dir | .slots.a.tip = $tip | .slots.a.branch = "dsh-ab/a"
    | .slots.a.snapshot = $branch
    | .current = "a" | .phase = "idle" | .confirmed = true
    | .history += [{ at: $at, action: "init", previousTarget: $prev, tip: $tip }]'
  ab_save_state
  ab_ok "initialized: current -> slot-a ($tip). Legacy worktree $prev_target kept as rollback."
  ab_log "next: ab.sh discover → ab.sh prepare (builds the new daily snapshot in slot b)"
}

cmd_prepare() {
  ab_is_initialized || ab_die "not initialized — run: ab.sh init --yes"
  [ -n "$AB_MAIN" ] || ab_die "no main clone resolved"
  # --source: legacy source-checkout prepare (git master / snapshot branches).
  if [ "$FLAG_SOURCE" = "1" ]; then
    cmd_prepare_source
    return $?
  fi
  # Default: npm-package slot (2026-08-14+). The slot is a DSH_HOME directory
  # holding one npm version; extensions are npm packages in its profile.
  cmd_prepare_npm
}

# cmd_prepare_npm — prepare a candidate slot from the npm dist-tag.
# Slot layout: <slot-dir> is a DSH_HOME (profiles/web + node_modules); the
# profile declares the official bundles plus extensions' npm packages.
cmd_prepare_npm() {
  local slot other cur dir
  slot="$FLAG_SLOT"
  cur=$(ab_current_slot)
  if [ -z "$slot" ]; then other=$(ab_other_slot); slot="$other"; fi
  [ "$slot" != "$cur" ] || ab_die "candidate slot '$slot' is the current slot — pick the other one"
  local phase confirmed
  phase=$(ab_state_get '.phase'); confirmed=$(ab_state_get '.confirmed')
  if [ "$phase" = "switched" ] && [ "$confirmed" = "false" ] && [ "$FLAG_FORCE" != "1" ]; then
    ab_die "current version is not yet confirmed stable — slot '$slot' is the only rollback; run 'ab.sh confirm' after the user confirms, or pass --force"
  fi

  local pkg tag version published
  pkg=$(ab_npm_pkg); tag=$(ab_npm_dist_tag)
  version="${FLAG_SNAPSHOT:-$(ab_npm_version "$tag")}"
  [ -n "$version" ] || ab_die "cannot resolve npm $pkg@$tag"
  published=$(ab_npm_published_at "$version")
  ab_log "preparing slot $slot <- npm $pkg@$version (published ${published:-?})"

  # nothing to do if this version is already running or already prepared here
  local cur_ver cand_phase cand_ver
  cur_ver=$(ab_slot_version "$cur")
  cand_phase=$(ab_state_get '.phase // "idle"')
  cand_ver=$(ab_state_get '.candidateVersion // ""')
  if [ "$version" = "$cur_ver" ]; then
    ab_warn "npm $pkg@$version is the running version; nothing new to prepare"
    return 0
  fi
  if [ "$cand_phase" = "prepared" ] && [ "$(ab_state_get '.candidate // ""')" = "$slot" ] && [ "$cand_ver" = "$version" ]; then
    ab_warn "npm $pkg@$version already prepared in slot $slot — run 'ab.sh verify' instead"
    return 0
  fi

  dir=$(ab_slot_dir "$slot")
  ab_log "slot dir: $dir"
  ab_lock "prepare-$$" || ab_die "another A/B operation holds the lock"
  trap 'ab_unlock' EXIT

  # --- (re)build the slot as an isolated DSH_HOME --------------------------
  rm -rf "$dir"; mkdir -p "$dir/profiles/web"
  if ! acc_npm_install "$dir" "$pkg" "$version"; then ab_warn "npm slot install failed"; ab_fail_prepare "$slot"; fi

  # --- extensions: install into the closure, link into the web profile -----
  # DSH resolves profile bundles from the profile dir's require paths
  # (profiles/web/node_modules and up). The extension packages live in the
  # SAME closure as the official dsh packages (profiles/node_modules) so their
  # peer deps (@deepseek-ai/*) resolve from one store; profiles/web/node_modules
  # then holds symlinks to them (mirroring the production layout).
  local exts n i ext extnpm extname
  exts=$(ab_config_get '.extensions // [] | length')
  i=0
  while [ "$i" -lt "$exts" ]; do
    ext=$(ab_config_get ".extensions[$i]")
    extname=$(printf '%s' "$ext" | jq -r '.name // ""')
    extnpm=$(printf '%s' "$ext" | jq -r '.npm // ""')
    if [ -n "$extnpm" ]; then
      ab_log "  closure add $extnpm -> $dir/profiles"
      if ! (cd "$dir/profiles" && pnpm install "$extnpm" --registry="$(ab_npm_registry)" 2>&1 | tail -3); then
        ab_warn "pnpm install $extnpm failed"; ab_fail_prepare "$slot"
      fi
      # bundle row = full package name (what resolveBundleDir looks up)
      ab_log "  profile bundle += $extnpm"
      python3 - "$dir/profiles/web/package.json" "$extnpm" <<'PY'
import json, sys
p, name = sys.argv[1], sys.argv[2]
d = json.load(open(p))
d.setdefault("dsh", {}).setdefault("profile", {}).setdefault("bundles", [])
if name not in d["dsh"]["profile"]["bundles"]:
    d["dsh"]["profile"]["bundles"].append(name)
json.dump(d, open(p, "w"), indent=2, ensure_ascii=False)
open(p, "a").write("\n")
PY
      # symlink the extension into the web profile's node_modules so the
      # bundle resolver can find it from the profile anchor
      local scope pname
      scope="${extnpm%%/*}"; pname="${extnpm#*/}"
      mkdir -p "$dir/profiles/web/node_modules/$scope"
      ln -sfn "$dir/profiles/node_modules/$extnpm" "$dir/profiles/web/node_modules/$scope/$pname"
    else
      ab_warn "extension $extname has no npm field — skipped (source mode: --source)"
    fi
    i=$((i + 1))
  done

  # --- slot launcher (current/bin/dsh -> npm CLI bin) -----------------------
  ab_ensure_slot_launcher_npm "$dir"
  # --- shared user data (sessions/storages @ ~/.dsh, not the slot) ----------
  ab_ensure_shared_userdata_patch "$dir"

  # --- web smoke on a staging port ------------------------------------------
  local wport whost wtimeout
  wport=$(ab_config_get '.web.port // 3081'); whost=$(ab_config_get '.web.host // "127.0.0.1"'); wtimeout=$(ab_config_get '.web.startupTimeoutSec // 180')
  if lsof -iTCP:"$wport" -sTCP:LISTEN >/dev/null 2>&1; then
    ab_warn "port $wport busy — skipping web smoke (use --keep with a free port, or check the config)"
  else
    if ! acc_web_smoke "$dir" "$wport" "$whost" "$wtimeout" "$FLAG_KEEP" "$FLAG_YES"; then
      ab_warn "web smoke FAILED"; ab_fail_prepare "$slot"
    fi
  fi

  # --- record prepared state ------------------------------------------------
  ab_state_set --arg at "$(ab_now)" --arg slot "$slot" --arg ver "$version" --arg pub "${published:-}" '
    .phase = "prepared" | .candidate = $slot | .candidateVersion = $ver
    | .candidateEvidence = { preparedAt: $at, slot: $slot, version: $ver, publishedAt: $pub, mode: "npm" }
    | .slots[$slot].version = $ver
    | .history += [{ at: $at, action: "prepare", slot: $slot, version: $ver, mode: "npm" }]'
  ab_save_state
  ab_ok "prepared slot $slot <- $pkg@$version (npm mode)"
  ab_log "next: ab.sh verify (re-check) → ab.sh e2e (browser) → ab.sh switch --yes"
}

cmd_prepare_source() {
  local slot other cur cand_branch dir
  slot="$FLAG_SLOT"
  cur=$(ab_current_slot)
  if [ -z "$slot" ]; then other=$(ab_other_slot); slot="$other"; fi
  [ "$slot" != "$cur" ] || ab_die "candidate slot '$slot' is the current slot — pick the other one"
  if [ -n "$FLAG_SNAPSHOT" ]; then
    cand_branch="$FLAG_SNAPSHOT"
  else
    local newest; newest=$(ab_snapshot_refs | head -1 || true)
    [ -n "$newest" ] || ab_die "no upstream snapshot branches"
    cand_branch=$(ab_snapshot_branch "$newest")
  fi
  local full_ref
  full_ref="refs/remotes/origin/$cand_branch"
  git -C "$AB_MAIN" rev-parse --verify "$full_ref" >/dev/null 2>&1 || ab_die "unknown snapshot ref: $cand_branch"
  # refuse only when there is genuinely nothing to do:
  #  - the snapshot is the RUNNING version, or
  #  - it was already prepared successfully in the candidate slot (verify instead)
  local cur_snap cand_slot_snap cand_slot_phase
  cur_snap=$(ab_slot_snapshot "$cur")
  cand_slot_phase=$(ab_state_get '.phase // "idle"')
  cand_slot_snap=$(ab_state_get '.candidateSnapshot // ""')
  if [ "$cand_branch" = "$cur_snap" ]; then
    ab_warn "snapshot $cand_branch is the running version; nothing new to prepare"
    return 0
  fi
  if [ "$cand_slot_phase" = "prepared" ] && [ "$(ab_state_get '.candidate // ""')" = "$slot" ] && [ "$cand_slot_snap" = "$cand_branch" ]; then
    ab_warn "snapshot $cand_branch already prepared in slot $slot — run 'ab.sh verify' instead"
    return 0
  fi
  dir=$(ab_slot_dir "$slot")
  ab_log "preparing slot $slot <- $cand_branch (dir $dir)"
  ab_lock "prepare-$$" || ab_die "another A/B operation holds the lock"
  trap 'ab_unlock' EXIT

  # --- checkout / reset the candidate slot --------------------------------
  local target_tip slot_tip
  target_tip=$(git -C "$AB_MAIN" rev-parse "$full_ref")
  slot_tip=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "")
  local reuse=0
  if [ -n "$slot_tip" ] && [ "$slot_tip" = "$target_tip" ] \
     && [ -d "$dir/node_modules" ] && [ -d "$dir/packages/core/tools/lib" ]; then
    reuse=1
  fi
  if [ "$reuse" = "1" ]; then
    ab_log "  slot already at $cand_branch with built lib — reusing (no checkout/install/build)"
  else
    if [ -d "$dir/.git" ] || git -C "$AB_MAIN" worktree list --porcelain 2>/dev/null | grep -q "worktree $dir"; then
      ab_log "  resetting existing slot worktree to $cand_branch"
      git -C "$dir" fetch origin 2>&1 | tail -1 || true
      git -C "$dir" checkout -B "dsh-ab/$slot" "$full_ref" 2>&1 | tail -2
      ab_log "  git clean -fdx (fresh node_modules per snapshot)"
      git -C "$dir" clean -fdx 2>&1 | tail -2 || true
    else
      ab_log "  git worktree add -B dsh-ab/$slot $dir $full_ref"
      git -C "$AB_MAIN" worktree add -B "dsh-ab/$slot" "$dir" "$full_ref" 2>&1 | tail -2
    fi
  fi
  local tip; tip=$(git -C "$dir" rev-parse HEAD)
  ab_state_set --arg slot "$slot" --arg dir "$dir" --arg snap "$cand_branch" --arg tip "$tip" '
    .slots[$slot].dir = $dir | .slots[$slot].snapshot = $snap | .slots[$slot].tip = $tip
    | .candidate = $slot | .candidateSnapshot = $snap | .phase = "preparing"' 
  ab_save_state

  # --- harness install + build --------------------------------------------
  if [ "$reuse" != "1" ]; then
    if ! acc_install "$dir"; then ab_warn "pnpm install failed"; ab_fail_prepare "$slot"; fi
    if ! acc_build "$dir" "$FLAG_SKIP_WEB"; then ab_warn "harness build failed"; ab_fail_prepare "$slot"; fi
  fi
  # 20260811+ snapshots removed bin/dsh; without a slot launcher the chain
  # ~/.local/bin/dsh -> current/bin/dsh breaks after cutover. Materialize it.
  ab_ensure_slot_launcher "$dir"

  # --- extensions (build + test against THIS candidate) --------------------
  local exts _e ev=()
  exts=$(ab_config_get '.extensions // [] | length')
  if [ "$exts" -gt 0 ]; then
    while read -r _e; do
      [ -n "$_e" ] || continue
      if ! ext_prepare "$_e" "$dir"; then ab_fail_prepare "$slot"; fi
      ev+=("$(ext_evidence "$_e" "$dir")")
    done < <(ab_config_items '.extensions // [] | .[]')
  else
    ab_warn "no extensions configured in $AB_CONFIG_FILE"
  fi

  # --- web smoke on a staging port -----------------------------------------
  local wport whost wtimeout
  wport=$(ab_config_get '.web.port // 3081'); whost=$(ab_config_get '.web.host // "127.0.0.1"'); wtimeout=$(ab_config_get '.web.startupTimeoutSec // 180')
  if lsof -iTCP:"$wport" -sTCP:LISTEN >/dev/null 2>&1; then
    ab_warn "port $wport busy — skipping web smoke (use --keep with a free port, or check the config)"
  else
    if ! acc_web_smoke "$dir" "$wport" "$whost" "$wtimeout" "$FLAG_KEEP" "$FLAG_YES"; then
      ab_warn "web smoke FAILED"; ab_fail_prepare "$slot"
    fi
  fi

  # --- record prepared state ----------------------------------------------
  local evjson
  if [ "${#ev[@]}" -gt 0 ]; then
    evjson=$(printf '%s\n' "${ev[@]}" | jq -s .)
  else
    evjson='[]'
  fi
  ab_state_set --arg at "$(ab_now)" --argjson ev "$evjson" --arg slot "$slot" --arg snap "$cand_branch" --arg tip "$tip" '
    .phase = "prepared" | .candidate = $slot | .candidateSnapshot = $snap
    | .candidateEvidence = { preparedAt: $at, slot: $slot, snapshot: $snap, tip: $tip, extensions: $ev }
    | .history += [{ at: $at, action: "prepare", slot: $slot, snapshot: $snap, tip: $tip }]'
  ab_save_state
  ok=1
  trap - EXIT; ab_unlock
  ab_ok "slot $slot prepared: $cand_branch @ ${tip:0:12}"
  ab_log "acceptance evidence recorded (ab.sh status --json). Next: review, then 'ab.sh switch --yes' (restarts dsh web!) or 'ab.sh rollback --yes'."
  return 0
}

# ab_fail_prepare <slot> — restore extension relinks, clear slot record, exit 1.
ab_fail_prepare() {
  local slot="$1"
  ab_warn "prepare failed — restoring extension relinks, leaving current untouched"
  local _e2
  while read -r _e2; do
    [ -n "$_e2" ] || continue
    ext_restore_all "$_e2"
  done < <(ab_config_items '.extensions // [] | .[]')
  ab_state_set --arg slot "$slot" --arg at "$(ab_now)" '
    .slots[$slot].snapshot = null | .slots[$slot].tip = null | .slots[$slot].version = null
    | .phase = "idle" | .candidate = null | .candidateSnapshot = null | .candidateVersion = null
    | .history += [{ at: $at, action: "prepare-failed", slot: $slot }]'
  ab_save_state
  ab_unlock
  exit 1
}

cmd_verify() {
  ab_verify_relinks
  local slot phase snap dir
  phase=$(ab_state_get '.phase')
  [ "$phase" = "prepared" ] || ab_die "nothing prepared (phase=$phase)"
  slot="$FLAG_SLOT"; [ -z "$slot" ] && slot=$(ab_state_get '.candidate')
  dir=$(ab_slot_dir "$slot")
  snap=$(ab_state_get '.candidateSnapshot')
  ab_log "verifying prepared candidate: slot $slot <- $snap (dir $dir)"
  ab_lock "verify-$$" || ab_die "another A/B operation holds the lock"
  trap 'ab_unlock' EXIT
  local allok=1
  local _e
  while read -r _e; do
    [ -n "$_e" ] || continue
    name=$(printf '%s' "$_e" | jq -r '.name'); repo=$(printf '%s' "$_e" | jq -r '.repo')
    ab_log "re-running tests for $name against $dir"
    ( cd "$repo" && DSH_SOURCE="$dir" DSH_TSCONFIG="$(printf '%s' "$_e" | jq -r '.tsconfigOut // "tsconfig.ab.json"')" pnpm test ) || allok=0
  done < <(ab_config_items '.extensions // [] | .[]')
  local wport whost wtimeout
  wport=$(ab_config_get '.web.port // 3081'); whost=$(ab_config_get '.web.host // "127.0.0.1"'); wtimeout=$(ab_config_get '.web.startupTimeoutSec // 180')
  acc_web_smoke "$dir" "$wport" "$whost" "$wtimeout" 0 || allok=0
  trap - EXIT; ab_unlock
  [ "$allok" = "1" ] && { ab_ok "verify passed — ready for switch (with user approval)"; return 0; }
  ab_err "verify FAILED — do NOT switch; investigate and re-prepare"
  return 1
}

cmd_e2e() {
  # Real-browser acceptance: verify the candidate's client plugins are actually
  # attached in a browser (frontend mount gate), record evidence, and in
  # acceptance.mode=auto this is what unblocks an unattended switch.
  local slot dir wport whost wtimeout
  slot="$FLAG_SLOT"
  if [ -z "$slot" ]; then
    slot=$(ab_state_get '.candidate // ""')
    [ -n "$slot" ] || slot=$(ab_current_slot)
  fi
  dir=$(ab_slot_dir "$slot")
  [ -n "$dir" ] && ab_slot_usable "$dir" || ab_die "slot $slot has no usable checkout ($dir)"
  wport="$FLAG_PORT"; [ -n "$wport" ] || wport=$(ab_config_get '.web.port // 3081')
  whost=$(ab_config_get '.web.host // "127.0.0.1"'); wtimeout=$(ab_config_get '.web.startupTimeoutSec // 180')
  ab_log "e2e acceptance for slot $slot ($dir)"
  ab_lock "e2e-$$" || ab_die "another A/B operation holds the lock"
  trap 'ab_unlock' EXIT
  if acc_e2e "$dir" "$wport" "$whost" "$wtimeout"; then
    ab_state_set --arg slot "$slot" --arg at "$(ab_now)" '
      .candidateEvidence.e2e = { at: $at, slot: $slot, ok: true }
      | .history += [{ at: $at, action: "e2e-pass", slot: $slot }]'
    ab_save_state
    trap - EXIT; ab_unlock
    ab_ok "e2e PASSED — client plugins attached in a real browser"
    return 0
  fi
  ab_state_set --arg slot "$slot" --arg at "$(ab_now)" '
    .candidateEvidence.e2e = { at: $at, slot: $slot, ok: false }
    | .history += [{ at: $at, action: "e2e-fail", slot: $slot }]'
  ab_save_state
  trap - EXIT; ab_unlock
  ab_err "e2e FAILED — do NOT switch; investigate client attachment"
  return 1
}

cmd_switch() {
  # Gate: manual mode requires --yes (user approval); auto mode requires a
  # passing e2e record (the user's standing choice in acceptance.mode).
  local mode e2e_ok
  mode=$(ab_config_get '.acceptance.mode // "manual"')
  if [ "$mode" = "auto" ]; then
    e2e_ok=$(ab_state_get '.candidateEvidence.e2e.ok // false')
    [ "$e2e_ok" = "true" ] || ab_die "acceptance.mode=auto but e2e has not passed — run: ab.sh e2e (or switch mode to manual and pass --yes)"
    ab_warn "acceptance.mode=auto: switching WITHOUT interactive user approval (e2e passed)"
  else
    [ "$FLAG_YES" = "1" ] || ab_die "switch cuts over current AND restarts dsh web (kills the agent's own session!) — pass --yes only after explicit user approval and a written handoff"
  fi
  local phase slot dir prev_target prev_slot at port
  phase=$(ab_state_get '.phase')
  [ "$phase" = "prepared" ] || ab_die "nothing prepared (phase=$phase); run prepare first"
  slot=$(ab_state_get '.candidate'); [ -n "$slot" ] || ab_die "no candidate slot recorded"
  dir=$(ab_slot_dir "$slot")
  ab_slot_usable "$dir" || ab_die "candidate dir missing: $dir"
  prev_slot=$(ab_current_slot)
  prev_target=$(readlink "$AB_SOURCE/current" 2>/dev/null || echo "$AB_CURRENT")
  at=$(ab_now)
  ab_log "CUTOVER: current -> slot $slot ($dir)"
  ab_log "  previous target: $prev_target (rollback: ab.sh rollback --yes)"
  ab_lock "switch-$$" || ab_die "another A/B operation holds the lock"
  trap 'ab_unlock' EXIT
  ln -sfn "$dir" "$AB_SOURCE/current"
  [ "$(readlink "$AB_SOURCE/current")" = "$dir" ] || ab_die "symlink cutover failed"
  ab_log "  verifying launcher boots from new current..."
  # shellcheck disable=SC2086
  $(ab_boot_cmd "$dir") --version >/dev/null 2>&1 || { ab_warn "launcher boot failed — rolling back symlink immediately"; ln -sfn "$prev_target" "$AB_SOURCE/current"; ab_die "rollback symlink restored to $prev_target"; }
  # the `dsh` command itself must keep working after cutover: its chain
  # (command -v dsh -> current/bin/dsh) resolves against the NEW current.
  # 20260811+ snapshots removed bin/dsh; prepare materializes a slot launcher,
  # so this should hold — fail loudly instead of shipping a broken `dsh`.
  local _dsh _dsh_resolved
  _dsh=$(command -v dsh || true)
  if [ -n "$_dsh" ]; then
    _dsh_resolved=$(resolve_link "$_dsh")
    ab_log "  launcher chain: $_dsh -> $_dsh_resolved (current -> $dir)"
    if [ -x "$dir/bin/dsh" ] || [ -x "$dir/apps/cli/lib/bin.js" ]; then
      ab_log "  launcher chain OK: bootable entry present in new current"
    else
      ab_warn "  launcher chain will break: $dir has no bin/dsh and no lib/bin.js — run 'ab.sh prepare --slot $slot' to materialize the slot launcher"
    fi
  fi
  ab_state_set --arg slot "$slot" --arg prev "$prev_slot" --arg prevtarget "$prev_target" --arg at "$at" --arg snap "$(ab_state_get '.candidateSnapshot')" '
    .current = $slot | .phase = "switched" | .confirmed = false
    | .lastSwitch = { at: $at, from: $prev, to: $slot, previousTarget: $prevtarget, snapshot: $snap }
    | .history += [{ at: $at, action: "switch", from: $prev, to: $slot, snapshot: $snap }]'
  ab_save_state
  ab_log "restarting dsh web from the new current (this terminates the agent session that invoked the switch)"
  ab_restart_web || { ab_warn "web restart failed — current is already cut over; run ab.sh rollback --yes"; exit 1; }
  trap - EXIT; ab_unlock
  ab_ok "switched: current -> slot $slot ($(ab_state_get '.candidateSnapshot')). Confirm stability with 'ab.sh confirm' once the user verifies."
}

cmd_confirm() {
  ab_verify_relinks
  # Production-acceptance gate (2026-08-11 incident): confirming means "the
  # RUNNING version is verifiably healthy through the PRODUCTION path" — not
  # just "the user said ok". Reject the confirm unless:
  #   1. the production port answers HTTP 200,
  #   2. the running web process actually comes from the current slot,
  #   3. the `dsh` launcher chain resolves into the current slot,
  #   4. every configured extension client id is in the production boot manifest.
  local port code cur dir proc html cids cid ok=1 launcher resolved
  port=$(ab_config_get '.web.productionPort // 3080')
  cur=$(ab_current_slot); dir=$(ab_slot_dir "$cur")
  ab_log "production acceptance (confirm gate) on http://127.0.0.1:$port ..."
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "http://127.0.0.1:$port/" 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then
    ab_ok "  production HTTP 200"
  else
    ab_err "  production web on :$port not answering HTTP 200 (got $code)"
    ok=0
  fi
  # the running process may reference the slot by its real path OR through the
  # `current` symlink (both mean "running the current slot's code").
  proc=$(ps aux | grep -E '[b]in\.ts web|apps/cli/[l]ib/bin\.js web' | grep -E "$dir|$AB_SOURCE/current" | head -1 || true)
  if [ -n "$proc" ]; then
    ab_ok "  running web process from current slot $dir"
  else
    ab_err "  no running web process from current slot $dir"
    ok=0
  fi
  launcher=$(command -v dsh || true)
  if [ -n "$launcher" ]; then
    resolved=$(resolve_link "$launcher")
    case "$resolved" in
      "$dir"/*|"$AB_SOURCE/current"/*) ab_ok "  launcher chain -> $resolved (inside current slot)" ;;
      *) ab_err "  launcher chain resolves to $resolved (outside current slot $dir)"; ok=0 ;;
    esac
  else
    ab_warn "  no 'dsh' on PATH — skipping launcher-chain check"
  fi
  cids=$(ab_config_get '.web.smokeClientIds // [] | .[]')
  if [ -n "$cids" ]; then
    html=$(curl -s --max-time 10 "http://127.0.0.1:$port/" 2>/dev/null || true)
    for cid in $cids; do
      if printf '%s' "$html" | grep -q "\"id\":\"$cid\""; then
        ab_ok "  client manifest: $cid present"
      else
        ab_err "  client manifest: $cid MISSING on production"
        ok=0
      fi
    done
  fi
  [ "$ok" = "1" ] || ab_die "production acceptance FAILED — do not confirm an unverifiable version; fix the running deployment and re-run confirm"
  local at; at=$(ab_now)
  ab_state_set --arg at "$at" '.confirmed = true | .history += [{ at: $at, action: "confirm" }]'
  ab_save_state
  ab_ok "current marked confirmed (production-accepted) — the rollback slot may now be recycled by the next prepare"
}

cmd_rollback() {
  [ "$FLAG_YES" = "1" ] || ab_die "rollback repoints current AND restarts dsh web — pass --yes only after explicit user approval and a written handoff"
  local prev_target at
  prev_target=$(ab_state_get '.lastSwitch.previousTarget // ""')
  [ -n "$prev_target" ] || ab_die "no previous target recorded"
  ab_slot_usable "$prev_target" || ab_die "previous target missing: $prev_target"
  at=$(ab_now)
  ab_lock "rollback-$$" || ab_die "another A/B operation holds the lock"
  trap 'ab_unlock' EXIT
  ab_log "ROLLBACK: current -> $prev_target"
  ln -sfn "$prev_target" "$AB_SOURCE/current"
  [ "$(readlink "$AB_SOURCE/current")" = "$prev_target" ] || ab_die "symlink rollback failed"
  # shellcheck disable=SC2086
  $(ab_boot_cmd "$prev_target") --version >/dev/null 2>&1 || { ab_warn "launcher boot failed after rollback"; }
  # map the target back to a slot if it is one
  local slot="" s
  for s in a b; do
    [ "$(ab_slot_dir "$s")" = "$prev_target" ] && slot="$s"
  done
  [ -n "$slot" ] || slot=$(ab_state_get '.lastSwitch.from // "a"')
  ab_state_set --arg slot "$slot" --arg at "$at" '
    .current = $slot | .phase = "rolled-back" | .confirmed = true | .candidate = null | .candidateSnapshot = null
    | .history += [{ at: $at, action: "rollback", to: $slot }]'
  ab_save_state
  ab_restart_web || ab_warn "web restart failed after rollback"
  trap - EXIT; ab_unlock
  ab_ok "rolled back to $prev_target (slot $slot)"
}

ab_restart_web() {
  ab_verify_relinks
  local port pid i code log cwd pids
  port=$(ab_config_get '.web.productionPort // 3080')
  pids=$(ps aux | grep -E '[b]in\.ts web|apps/cli/[l]ib/bin\.js web' | awk '{print $2}')
  if [ -n "$pids" ]; then
    ab_warn "  stopping running dsh web instance(s): $(printf '%s' "$pids" | tr '\n' ' ')"
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
  fi
  i=0
  while [ "$i" -lt 60 ]; do
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || break
    i=$((i+1)); sleep 1
  done
  # restart from the same cwd the previous server used (workspace-root default
  # follows the launch cwd): record it from the dying process when possible,
  # else fall back to the main clone (matches the original restart script).
  local firstpid=""
  [ -n "$pids" ] && firstpid=$(printf '%s' "$pids" | head -1)
  cwd=""
  [ -n "$firstpid" ] && cwd=$(lsof -a -p "$firstpid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1) || true
  [ -n "$cwd" ] && [ -d "$cwd" ] || cwd="${AB_MAIN:-$HOME}"
  # nohup'd dsh web must find `node` on PATH: a bare `dsh` from a non-login
  # shell fails with "exec: node: not found" (the launcher execs node). Pin the
  # node bin dir from the current shell and use the resolved launcher path.
  local node_bin="" boot_dir
  command -v node >/dev/null 2>&1 && node_bin=$(dirname "$(command -v node)")
  if [ -z "$node_bin" ]; then
    # fallback when `node` is not on this shell's PATH (nohup subshells and
    # launchd/guard contexts often have a minimal PATH): common install dirs.
    for _nb in /opt/homebrew/bin /usr/local/bin; do
      [ -x "$_nb/node" ] && { node_bin="$_nb"; break; }
    done
  fi
  log="$AB_SOURCE/web.log"
  # restart boots the NEW current (the symlink was already cut over)
  boot_dir=$(readlink "$AB_SOURCE/current" 2>/dev/null || echo "$AB_CURRENT")
  # npm-distribution slots are isolated DSH_HOMEs: the web server must see
  # DSH_HOME=<slot-dir> or it loads the user-level ~/.dsh profile instead.
  local home_arg=""
  if [ -d "$boot_dir/profiles/web" ]; then
    home_arg="DSH_HOME=$boot_dir"
    ab_log "  npm slot: DSH_HOME=$boot_dir"
  fi
  ab_log "  starting: nohup $(ab_boot_cmd "$boot_dir") web (cwd $cwd, log $log)"
  # shellcheck disable=SC2086
  ( cd "$cwd" && PATH="${node_bin:+$node_bin:}$PATH" nohup env $home_arg $(ab_boot_cmd "$boot_dir") web >"$log" 2>&1 & echo $! > "$AB_SOURCE/web.pid" )
  i=0; code=000
  while [ "$i" -lt 180 ]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$port/" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && break
    i=$((i+1)); sleep 1
  done
  if [ "$code" = "200" ]; then
    ab_ok "  web UP on http://127.0.0.1:$port after ${i}s"
    return 0
  fi
  ab_err "  web NOT up after ${i}s (last HTTP $code); tail:"
  tail -30 "$log" >&2 || true
  return 1
}

cmd_stage() {
  # Boot one slot's web on a STAGING port while production keeps running —
  # a second instance sharing ~/.dsh, safe only for read-only inspection.
  # Coexistence is detected and requires explicit approval (--yes).
  local slot port
  slot="$FLAG_SLOT"
  [ -n "$slot" ] || ab_die "usage: ab.sh stage --slot a|b [--port N] [--keep]"
  local dir; dir=$(ab_slot_dir "$slot")
  [ -n "$dir" ] && ab_slot_usable "$dir" || ab_die "slot $slot has no usable checkout ($dir)"
  port="$FLAG_PORT"
  [ -n "$port" ] || port=$(ab_config_get '.web.port // 3081')
  if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    ab_die "port $port already in use — pass --port <free>"
  fi
  if ab_warn_coexistence; then
    if [ "$FLAG_YES" != "1" ]; then
      ab_die "a dsh web instance is already running — a second instance shares ~/.dsh (sessions/storages) and must be READ-ONLY inspection only. Pass --yes to confirm you understand, then it will boot."
    fi
  fi
  ab_log "booting slot $slot (${dir}) web on http://127.0.0.1:$port — production instance keeps running; this one is READ-ONLY inspection."
  if [ "$FLAG_KEEP" = "1" ]; then
    # shellcheck disable=SC2086
    ( cd "$dir" && nohup $(ab_boot_cmd "$dir") web --port "$port" >"$AB_SOURCE/web-stage-$slot.log" 2>&1 & echo $! > "$AB_SOURCE/stage-$slot.pid" )
    ab_ok "staging server up (log $AB_SOURCE/web-stage-$slot.log, pid $(cat "$AB_SOURCE/stage-$slot.pid"))"
    ab_log "  stop it: kill \$(lsof -tiTCP:$port -sTCP:LISTEN)   # listener pid may differ from the wrapper"
  else
    # shellcheck disable=SC2086
    ( cd "$dir" && exec $(ab_boot_cmd "$dir") web --port "$port" )
  fi
}

cmd_cleanup() {
  local dirs=("$@")
  [ -n "$AB_MAIN" ] || ab_die "no main clone resolved"
  ab_log "worktrees of $AB_MAIN:"
  git -C "$AB_MAIN" worktree list
  if [ "${#dirs[@]}" -gt 0 ] && [ "$FLAG_YES" = "1" ]; then
    local d cur
    cur=$(ab_current_dir)
    for d in "${dirs[@]}"; do
      [ "$(cd "$d" && pwd)" != "$(cd "$cur" && pwd)" ] || { ab_warn "refusing to remove the current slot: $d"; continue; }
      ab_log "removing worktree $d"
      git -C "$AB_MAIN" worktree remove "$d" 2>&1 | tail -2 || ab_warn "remove failed for $d (try: git worktree remove --force)"
    done
  else
    ab_log "pass explicit worktree paths plus --yes to remove (never the current slot)"
  fi
}

cmd_help() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

case "$CMD" in
  status) cmd_status ;;
  discover) cmd_discover ;;
  notes) cmd_notes ;;
  init) cmd_init ;;
  prepare) cmd_prepare ;;
  verify) cmd_verify ;;
  e2e) cmd_e2e ;;
  stage) cmd_stage ;;
  switch) cmd_switch ;;
  confirm) cmd_confirm ;;
  rollback) cmd_rollback ;;
  cleanup) shift || true; cmd_cleanup "$@" ;;
  help|-h|--help) cmd_help ;;
  *) ab_err "unknown command: $CMD"; cmd_help; exit 1 ;;
esac
