#!/usr/bin/env bash
# extension.sh — attach/build/test an extension against a specific DSH slot.
# Sourced by ab.sh. Mutates only: the extension repo's node_modules symlinks,
# a generated per-slot tsconfig (gitignored), and ~/.dsh/skills copies.
# Extensions are passed around as compact JSON strings (jq -c output).
set -euo pipefail

# Per-attempt relink journal: "repo|link|old-target" lines in a temp file, so
# every extension's relinks can be restored even after a later one fails.
AB_RELINK_JOURNAL="${AB_RELINK_JOURNAL:-$(mktemp -t dsh-ab-relink.XXXXXX)}"

# ext_relink <ext-json> <candidate-dir> <ext-repo>
#   Re-point node_modules/<pkg> symlinks at <candidate-dir>/<rel>; journal old
#   targets for ext_restore_all.
ext_relink() {
  local ext="$1" cand="$2" repo="$3"
  local relink_map entry link rel old
  relink_map=$(printf '%s' "$ext" | jq -c '.relink // {}')
  [ "$relink_map" = "{}" ] && return 0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    link=$(printf '%s' "$entry" | jq -r '.key')
    rel=$(printf '%s' "$entry" | jq -r '.value')
    old=""
    [ -L "$repo/$link" ] && old=$(readlink "$repo/$link") || true
    mkdir -p "$repo/$(dirname "$link")"
    ln -sfn "$cand/$rel" "$repo/$link"
    printf '%s|%s|%s\n' "$repo" "$link" "$old" >> "$AB_RELINK_JOURNAL"
    ab_log "  relink $link -> $cand/$rel"
  done < <(printf '%s' "$relink_map" | jq -c 'to_entries[]')
}

# ext_restore_all <ext-json...>  — restore every journaled relink
ext_restore_all() {
  [ -f "$AB_RELINK_JOURNAL" ] || return 0
  local line repo link old
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    repo="${line%%|*}"; rest="${line#*|}"
    link="${rest%%|*}"; old="${rest#*|}"
    if [ -n "$old" ]; then ln -sfn "$old" "$repo/$link"; else rm -f "$repo/$link"; fi
  done < "$AB_RELINK_JOURNAL"
  : > "$AB_RELINK_JOURNAL"
}

# ext_make_tsconfig <ext-json> <candidate-dir> <ext-repo>
#   Materialize <repo>/<tsconfigOut> by rewriting the harness source prefix in
#   the extension's tsconfig so typecheck/build resolve the candidate's lib.
ext_make_tsconfig() {
  local ext="$1" cand="$2" repo="$3"
  local src out out_abs prefix
  src="$repo/$(printf '%s' "$ext" | jq -r '.tsconfig // "tsconfig.json"')"
  out="$(printf '%s' "$ext" | jq -r '.tsconfigOut // "tsconfig.ab.json"')"
  out_abs="$repo/$out"
  prefix="$(ab_config_get '.sourcePathPrefix // ""')"
  if [ -z "$prefix" ]; then
    ab_warn "no sourcePathPrefix in config; skipping per-slot tsconfig for $(printf '%s' "$ext" | jq -r '.name')"
    return 0
  fi
  python3 - "$src" "$out_abs" "$prefix" "$cand" <<'PY'
import sys
src, out, prefix, cand = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
assert prefix in text, f"prefix {prefix!r} not found in {src}"
open(out, "w", encoding="utf-8").write(text.replace(prefix, cand))
PY
  ab_log "  tsconfig -> $out_abs (prefix $prefix -> $cand)"
}

# ext_run <ext-json> <candidate-dir> <ext-repo> <field>  — run one script
ext_run() {
  local ext="$1" cand="$2" repo="$3" field="$4"
  local cmd tsout
  cmd=$(printf '%s' "$ext" | jq -r ".${field} // empty")
  [ -n "$cmd" ] || { ab_log "  (no $field configured)"; return 0; }
  tsout=$(printf '%s' "$ext" | jq -r '.tsconfigOut // "tsconfig.ab.json"')
  ab_log "  $field: $cmd"
  ( cd "$repo" && DSH_SOURCE="$cand" DSH_TSCONFIG="$tsout" eval "$cmd" )
}

# ext_install_skills <ext-json> <ext-repo>
#   Copy the extension's skills into ~/.dsh/skills so the running harness
#   picks them up (same convention as dsh-session-recovery / dsh-track).
ext_install_skills() {
  local ext="$1" repo="$2" i src dst
  local skills
  skills=$(printf '%s' "$ext" | jq -r '.skills // [] | .[]')
  [ -n "$skills" ] || return 0
  mkdir -p "$HOME/.dsh/skills"
  for i in $skills; do
    src="$repo/$i"
    [ -d "$src" ] || { ab_warn "  skill source missing: $src"; continue; }
    dst="$HOME/.dsh/skills/$(basename "$i")"
    rm -rf "$dst"
    cp -R "$src" "$dst"
    ab_log "  skill -> $dst"
  done
}

# ext_prepare <ext-json> <candidate-dir>
#   Attach + build + test one extension against the candidate. On failure,
#   restores relink + tsconfig and returns non-zero.
ext_prepare() {
  local ext="$1" cand="$2"
  local name repo
  name=$(printf '%s' "$ext" | jq -r '.name')
  repo=$(printf '%s' "$ext" | jq -r '.repo')
  ab_log "extension: $name (repo $repo)"
  [ -d "$repo" ] || ab_die "extension repo missing: $repo"
  ext_relink "$ext" "$cand" "$repo"
  ext_make_tsconfig "$ext" "$cand" "$repo"
  local ok=1
  if ! ext_run "$ext" "$cand" "$repo" "typecheck"; then ok=0; fi
  if [ "$ok" = "1" ] && ! ext_run "$ext" "$cand" "$repo" "build"; then ok=0; fi
  if [ "$ok" = "1" ] && ! ext_run "$ext" "$cand" "$repo" "test"; then ok=0; fi
  if [ "$ok" = "1" ]; then
    ext_install_skills "$ext" "$repo"
    ab_ok "extension $name OK against $cand"
    return 0
  fi
  ab_warn "extension $name FAILED against $cand — restoring relink/tsconfig"
  ext_restore_all
  rm -f "$repo/$(printf '%s' "$ext" | jq -r '.tsconfigOut // "tsconfig.ab.json"')"
  return 1
}

# ext_evidence <ext-json> <candidate-dir>  — build a JSON evidence fragment
ext_evidence() {
  local ext="$1" cand="$2"
  local name repo tip dirty
  name=$(printf '%s' "$ext" | jq -r '.name')
  repo=$(printf '%s' "$ext" | jq -r '.repo')
  tip=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)
  dirty=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  jq -n --arg name "$name" --arg tip "$tip" --argjson dirty "$dirty" \
    --arg dsh "$cand" \
    '{ name: $name, repoTip: $tip, dirtyFiles: $dirty, builtAgainst: $dsh }'
}
