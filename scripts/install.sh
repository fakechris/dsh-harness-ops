#!/usr/bin/env bash
# dsh-harness-ops installer — one command to install (or re-install) this
# toolbox on a machine:
#   1. copies the four skills into ~/.dsh/skills (the default scan dir),
#   2. installs the published dsh-restart-recover bundle into the `web`
#      profile (via `dsh plugin add`, the official pnpm-backed mechanism),
#   3. prints a hint for the optional web-guard daemon.
# Idempotent — safe to re-run after every update. Skills come from this git
# checkout; the bundle is a separately published npm artifact.
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
PLUGIN_PACKAGE="@fakechris/dsh-restart-recover"
PLUGIN_MANIFEST="$ROOT/plugins/dsh-restart-recover/package.json"
if [ -f "$PLUGIN_MANIFEST" ]; then
  if ! command -v dsh >/dev/null 2>&1; then
    echo "  warn: 'dsh' not on PATH — skipping profile bundle install (skills are installed)"
  else
    PLUGIN_VERSION=$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' "$PLUGIN_MANIFEST" | head -1)
    [ -n "$PLUGIN_VERSION" ] || { echo "error: cannot read bundle version from $PLUGIN_MANIFEST"; exit 1; }
    PLUGIN_SPEC="$PLUGIN_PACKAGE@$PLUGIN_VERSION"
    echo "  bundle: installing $PLUGIN_SPEC into the web profile (registry artifact)..."
    # A local path makes pnpm persist a link: dependency. Its ignored lib/
    # output can disappear after a clean and then prevent dsh web from booting.
    # The published tarball owns lib/, so production profiles use it directly.
    if dsh plugin --profile web add "$PLUGIN_SPEC" >/tmp/dsh-harness-ops-plugin.log 2>&1; then
      echo "  bundle -> web profile: $PLUGIN_SPEC"
    else
      echo "  warn: 'dsh plugin --profile web add $PLUGIN_SPEC' failed (see /tmp/dsh-harness-ops-plugin.log)"
      echo "        check the registry and profile with: dsh plugin --profile web ls"
    fi
  fi
else
  echo "  warn: plugin manifest missing: $PLUGIN_MANIFEST"
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
