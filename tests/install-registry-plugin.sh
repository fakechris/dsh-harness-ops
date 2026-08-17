#!/usr/bin/env bash
# Verify the installer registers the published restart-recover artifact, not a
# local checkout link whose ignored lib/ directory can disappear.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/dsh-harness-ops-install.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/skills"
cat > "$TMP/bin/dsh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$DSH_INSTALL_TEST_ARGS"
EOF
cat > "$TMP/bin/pnpm" <<'EOF'
#!/usr/bin/env bash
echo "pnpm must not run during registry bundle installation" >&2
exit 99
EOF
chmod +x "$TMP/bin/dsh" "$TMP/bin/pnpm"

export HOME="$TMP/home"
export DSH_SKILLS_DIR="$TMP/skills"
export DSH_INSTALL_TEST_ARGS="$TMP/dsh-args"
export PATH="$TMP/bin:/usr/bin:/bin:/usr/sbin:/sbin"

bash "$ROOT/scripts/install.sh" > "$TMP/install.log"

VERSION=$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' \
  "$ROOT/plugins/dsh-restart-recover/package.json" | head -1)
EXPECTED="plugin --profile web add @fakechris/dsh-restart-recover@$VERSION"
ACTUAL=$(cat "$DSH_INSTALL_TEST_ARGS")
[ "$ACTUAL" = "$EXPECTED" ] || {
  echo "expected: $EXPECTED" >&2
  echo "actual:   $ACTUAL" >&2
  exit 1
}

grep -F "bundle -> web profile: @fakechris/dsh-restart-recover@$VERSION" "$TMP/install.log" >/dev/null
echo "install-registry-plugin: pass"
