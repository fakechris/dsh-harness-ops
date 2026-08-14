#!/usr/bin/env bash
# dsh-harness-ops updater — one command to update this toolbox from git and
# re-apply it locally:
#   1. git fetch + fast-forward main,
#   2. rebuild the bundle plugin's lib (a git pull fetches SOURCES, not built
#      artifacts — the plugin's `prepare` script compiles lib/ self-contained),
#   3. re-run the installer (skills re-copy, bundle re-add — idempotent).
# No manual "packaging" step is needed: git is the distribution unit and the
# plugin builds itself on install (official pattern, docs/RELEASE.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLD="$(cat "$ROOT/VERSION" 2>/dev/null || echo unknown)"

echo "[dsh-harness-ops] updating $OLD -> origin/main ..."
git -C "$ROOT" fetch origin 2>&1 | tail -1 || true
git -C "$ROOT" pull --ff-only origin main

NEW="$(cat "$ROOT/VERSION" 2>/dev/null || echo unknown)"

# ---- toolchain slot resolution (2026-08-14) ----
# The npm/profile-layout slots (formal release) carry no dev toolchain
# (no node_modules/.bin/tsc — the pnpm closure is runtime-only). Resolve a
# source-layout slot that has one; the build runs against that slot's types.
resolve_toolchain() {
  local cur="$HOME/.dsh/source/current"
  [ -x "$cur/node_modules/.bin/tsc" ] && { printf '%s' "$cur"; return 0; }
  local d
  for d in "$HOME"/.dsh/source/slot-*; do
    [ -x "$d/node_modules/.bin/tsc" ] && { printf '%s' "$d"; return 0; }
  done
  printf '%s' "$cur"
}
DSH_SOURCE="${DSH_SOURCE:-$(resolve_toolchain)}"
export DSH_SOURCE
echo "  toolchain: $DSH_SOURCE"

# rebuild the bundle plugin's lib from the freshly fetched sources
PLUGIN="$ROOT/plugins/dsh-restart-recover"
if [ -d "$PLUGIN" ]; then
  # The bundle plugin declares no dependencies (profile injects them at
  # runtime), so tsc resolves @deepseek-ai/* types through node_modules
  # links — self-heal them against the toolchain slot, layout-aware:
  # legacy monorepo path first, npm profile closure fallback.
  mkdir -p "$PLUGIN/node_modules/@deepseek-ai"
  while IFS='|' read -r pkg rel; do
    [ -n "$pkg" ] || continue
    link="@deepseek-ai/$pkg"
    target="$DSH_SOURCE/$rel"
    { [ -e "$target" ] || [ -L "$target" ]; } || target="$DSH_SOURCE/profiles/node_modules/$link"
    { [ -e "$target" ] || [ -L "$target" ]; } || { echo "  [relink] WARN: $link unresolvable under $DSH_SOURCE"; continue; }
    ln -sfn "$target" "$PLUGIN/node_modules/$link"
    echo "  [relink] $link -> $target"
  done <<'EOF'
cordis|vendor/cordis
dsh-agent|packages/core/agent
dsh-session|packages/core/session
EOF
  ln -sfn "$DSH_SOURCE/vendor/cordis" "$PLUGIN/node_modules/cordis" 2>/dev/null \
    || ln -sfn "$DSH_SOURCE/profiles/node_modules/@deepseek-ai/cordis" "$PLUGIN/node_modules/cordis" 2>/dev/null \
    || true
  echo "  rebuilding $PLUGIN/lib ..."
  ( cd "$PLUGIN" && pnpm install --frozen-lockfile >/dev/null 2>&1 || pnpm install >/dev/null 2>&1 )
  ( cd "$PLUGIN" && node scripts/dsh-env.mjs tsc -p tsconfig.json )
  echo "  plugin lib rebuilt"
fi

# re-sync skills + profile bundle (idempotent)
bash "$ROOT/scripts/install.sh"

if [ "$OLD" != "$NEW" ]; then
  echo "[dsh-harness-ops] updated $OLD -> $NEW. Changes:"
  sed -n "/## \[$NEW\]/,/^## \[/p" "$ROOT/CHANGELOG.md" | head -30
else
  echo "[dsh-harness-ops] already at $NEW (no new version on origin/main)."
fi
