#!/usr/bin/env bash
# dsh-harness-ops installer — one command to install (or re-install) this
# toolbox on a machine:
#   1. copies the three skills into ~/.dsh/skills (the default scan dir),
#   2. installs the dsh-restart-recover bundle into the `web` profile
#      (via `dsh plugin add`, the official pnpm-backed mechanism),
#   3. prints a hint for the optional web-guard daemon.
# Idempotent — safe to re-run after every update. Distribution unit is this
# git checkout; there is no npm publish (see docs/RELEASE.md).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo unknown)"
SKILLS_DST="${DSH_SKILLS_DIR:-$HOME/.dsh/skills}"

echo "[dsh-harness-ops] installing v$VERSION from $ROOT"

# --- 1) skills --------------------------------------------------------------
mkdir -p "$SKILLS_DST"
installed=0
for s in dsh-snapshot-ab dsh-web-guard dsh-session-recovery dsh-web-doctor; do
  src="$ROOT/skills/$s"
  [ -d "$src" ] || { echo "  warn: skill dir missing: $src"; continue; }
  rm -rf "$SKILLS_DST/$s"
  cp -R "$src" "$SKILLS_DST/$s"
  echo "  skill -> $SKILLS_DST/$s"
  installed=1
done
[ "$installed" = "1" ] || { echo "error: no skills found in $ROOT/skills"; exit 1; }

# --- 2) bundle plugin into the web profile -----------------------------------
PLUGIN="$ROOT/plugins/dsh-restart-recover"
if [ -d "$PLUGIN" ]; then
  if ! command -v dsh >/dev/null 2>&1; then
    echo "  warn: 'dsh' not on PATH — skipping profile bundle install (skills are installed)"
  else
    echo "  bundle: installing $PLUGIN into the web profile (pnpm-backed)..."
    # first install/build the plugin's own deps, then let `dsh plugin add`
    # (which forwards to pnpm in the profile dir) register the bundle layer.
    ( cd "$PLUGIN" && pnpm install --frozen-lockfile >/dev/null 2>&1 || pnpm install >/dev/null 2>&1 )
    if ( cd "$PLUGIN" && dsh plugin --profile web add . ) >/tmp/dsh-harness-ops-plugin.log 2>&1; then
      echo "  bundle -> web profile: @deepseek-ai/dsh-restart-recover"
    else
      echo "  warn: 'dsh plugin --profile web add .' failed (see /tmp/dsh-harness-ops-plugin.log)"
      echo "        if the bundle is already linked, this is fine; check with: dsh plugin --profile web ls"
    fi
  fi
else
  echo "  warn: plugin dir missing: $PLUGIN"
fi

# --- 3) one-command doctor entry on PATH -------------------------------------
# The out-of-band doctor must be a SHORT command the user can type when the
# web is down (agent/GUI unavailable): `dsh-doctor --fix --restart`.
if [ -x "$SKILLS_DST/dsh-web-doctor/scripts/doctor.sh" ]; then
  mkdir -p "$HOME/.local/bin"
  ln -sfn "$SKILLS_DST/dsh-web-doctor/scripts/doctor.sh" "$HOME/.local/bin/dsh-doctor"
  echo "  doctor -> $HOME/.local/bin/dsh-doctor  (usage: dsh-doctor [--fix] [--restart])"
fi

# --- 4) optional daemon -------------------------------------------------------
if [ -f "$ROOT/skills/dsh-web-guard/scripts/install.sh" ]; then
  echo
  echo "  optional: install the self-healing daemon (launchd/systemd):"
  echo "    bash $ROOT/skills/dsh-web-guard/scripts/install.sh"
fi

echo "[dsh-harness-ops] installed v$VERSION — skills are live; restart any running agent to pick up skill catalog changes."
