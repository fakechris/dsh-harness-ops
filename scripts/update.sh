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

# rebuild the bundle plugin's lib from the freshly fetched sources
PLUGIN="$ROOT/plugins/dsh-restart-recover"
if [ -d "$PLUGIN" ]; then
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
