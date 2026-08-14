#!/usr/bin/env bash
# acceptance.sh — candidate-slot acceptance gates for the A/B rotation.
# Sourced by ab.sh. Never touches the current/production slot or the running
# server; the candidate is exercised in isolation (its own dir + staging port).
set -euo pipefail

# acc_e2e <candidate-dir> <port> <host> <timeout>
#   Real-browser E2E: boot the candidate on a staging port, then use
#   agent-browser to verify the configured client plugins' UI is actually
#   attached (e.g. #dsh-track-fab exists — the plugin's apply() ran and the
#   frontend rendered it). This is the "frontend really mounted" gate that
#   manifest grep alone cannot prove. Requires agent-browser on PATH.
acc_e2e() {
  local dir="$1" port="$2" host="$3" timeout="$4"
  local allok=1 pid log i code sel id html
  command -v agent-browser >/dev/null 2>&1 || { ab_err "e2e: agent-browser not on PATH"; return 1; }
  log="$(mktemp -t dsh-ab-e2e.XXXXXX).log"
  ab_log "e2e: booting $(ab_boot_cmd "$dir") web on $host:$port for browser checks (log $log)"
  # shellcheck disable=SC2086
  ( cd "$dir" && nohup $(ab_boot_cmd "$dir") web --port "$port" --host "$host" >"$log" 2>&1 & echo $! > "$log.pid" )
  pid=$(cat "$log.pid")
  i=0; code=000
  while [ "$i" -lt "$timeout" ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://$host:$port/" 2>/dev/null || true)
    [ "$code" = "200" ] && break
    i=$((i + 1)); sleep 1
  done
  if [ "$code" != "200" ]; then
    ab_err "e2e: server never answered 200 (pid $pid); log tail:"; tail -15 "$log" >&2 || true
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  ab_ok "e2e: server up (HTTP 200 after ${i}s)"
  local checks
  checks=$(ab_config_get '.acceptance.e2e.checks // [] | length')
  if [ "$checks" = "0" ]; then
    ab_warn "e2e: no acceptance.e2e.checks configured — nothing to verify"
    allok=0
  fi
  while read -r c; do
    [ -n "$c" ] || continue
    id=$(printf '%s' "$c" | jq -r '.id // ""')
    sel=$(printf '%s' "$c" | jq -r '.selector // ""')
    [ -n "$id" ] && [ -n "$sel" ] || continue
    agent-browser open "http://$host:$port/" >/dev/null 2>&1 || true
    sleep 1
    html=$(agent-browser eval "!!document.querySelector('$sel')" 2>/dev/null | tail -1)
    if printf '%s' "$html" | grep -q 'true'; then
      ab_ok "  e2e: $id -> $sel present"
    else
      ab_err "  e2e: $id -> $sel MISSING (client not attached in real browser)"
      allok=0
    fi
  done < <(ab_config_items '.acceptance.e2e.checks // [] | .[]')
  # cleanup: TERM then force-free the port
  kill "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 15 ] && lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do i=$((i+1)); sleep 1; done
  if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null || true
  fi
  [ "$allok" = "1" ]
}

# acc_install <candidate-dir>   — pnpm install --frozen-lockfile in the slot
acc_install() {
  local dir="$1"
  ab_log "pnpm install (frozen lockfile) in $dir"
  ( cd "$dir" && pnpm install --frozen-lockfile 2>&1 | tail -5 )
}

# acc_npm_install <slot-dir> <pkg> <version> — install an npm-distribution slot.
# The slot is a DSH_HOME: profiles/web declares the official bundles; the dsh
# CLI lives in profiles/node_modules (pnpm closure) so bin.js resolves from
# there. Uses pnpm (not npm): DSH's profile boot expects
# profiles/node_modules/@deepseek-ai/<pkg> to be symlinks into a store (pnpm's
# layout), and its healProfilesModuleFallback rejects real directories.
acc_npm_install() {
  local dir="$1" pkg="$2" version="$3" reg
  reg=$(ab_npm_registry)
  ab_log "npm slot install: $pkg@$version (registry $reg, pnpm closure)"
  mkdir -p "$dir/profiles/web"
  cat > "$dir/profiles/web/package.json" <<'EOF'
{
  "name": "dsh-profile-web",
  "private": true,
  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"] } },
  "dependencies": {}
}
EOF
  mkdir -p "$dir/profiles/node_modules"
  cat > "$dir/profiles/package.json" <<'EOF'
{
  "name": "dsh-slot-closure",
  "private": true,
  "dependencies": {}
}
EOF
  ( cd "$dir/profiles" && pnpm install "$pkg@$version" --registry="$reg" 2>&1 | tail -4 )
  [ -x "$dir/profiles/node_modules/.bin/dsh" ] || [ -f "$dir/profiles/node_modules/$pkg/bin.js" ] \
    || { ab_err "npm slot install: dsh CLI not found after install"; return 1; }
  ab_log "  npm slot closure installed: $(ls "$dir/profiles/node_modules/@deepseek-ai/" 2>/dev/null | wc -l | tr -d ' ') @deepseek-ai packages"
}

# acc_build <candidate-dir> <skip-web>
acc_build() {
  local dir="$1" skip_web="${2:-0}"
  ab_log "build:lib (host+client types & runtime) in $dir"
  ( cd "$dir" && npm run build:lib 2>&1 | tail -6 )
  if [ "$skip_web" = "0" ]; then
    ab_log "build:web (frontend bundle) in $dir"
    ( cd "$dir" && npm run build:web 2>&1 | tail -6 )
  else
    ab_warn "skipping build:web (--skip-web)"
  fi
}

# acc_web_smoke <candidate-dir> <port> <host> <timeout> <keep>
#   Boot <candidate>/bin/dsh web on a staging port; poll HTTP; kill unless keep.
#   Returns 0 if the server answered every smoke path.
acc_web_smoke() {
  local dir="$1" port="$2" host="$3" timeout="$4" keep="${5:-0}" approval="${6:-0}"
  local log pid i code p allok=1 ws_arg
  # port must be free before booting a staging instance
  if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    ab_err "port $port already in use — pick a free staging port (config web.port)"
    return 1
  fi
  # coexistence guard: booting a second dsh web shares ~/.dsh state
  if ab_warn_coexistence; then
    if [ "$keep" = "1" ] && [ "$approval" != "1" ]; then
      ab_warn "  refusing to leave a SECOND instance running without explicit approval — auto-stopping after the smoke; pass --yes to keep it for manual review"
      keep=0
    fi
  fi
  log="$(mktemp -t dsh-ab-smoke.XXXXXX).log"
  # --workspace-root exists on some snapshots and was removed on others; ask the
  # candidate's own CLI before passing it (acceptance must not assume flags).
  ws_arg=""
  # shellcheck disable=SC2086
  if ( cd "$dir" && $(ab_boot_cmd "$dir") web --help 2>&1 | grep -q -- '--workspace-root' ); then
    ws_arg="--workspace-root $(mktemp -d -t dsh-ab-ws.XXXXXX)"
  else
    ab_warn "  candidate's dsh web has no --workspace-root flag; smoke without it"
  fi
  ab_log "smoke: $(ab_boot_cmd "$dir") web --port $port (log $log)"
  # npm-distribution slots are isolated DSH_HOMEs: their profiles live under
  # <slot>/profiles, so the booted web must see DSH_HOME=<slot-dir> or it would
  # load the USER-level ~/.dsh profile (and any source-linked extensions in it).
  # Source-checkout slots (git mode) share the user's ~/.dsh and need no HOME.
  local env_prefix=""
  if [ -d "$dir/profiles/web" ]; then
    env_prefix="DSH_HOME=$dir"
    ab_log "  npm slot: DSH_HOME=$dir"
  fi
  # shellcheck disable=SC2086
  ( cd "$dir" && nohup env $env_prefix $(ab_boot_cmd "$dir") web --port "$port" --host "$host" $ws_arg >"$log" 2>&1 & echo $! > "$log.pid" )
  pid=$(cat "$log.pid")
  i=0
  while [ "$i" -lt "$timeout" ]; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://$host:$port/" 2>/dev/null || true)
    [ "$code" = "200" ] && break
    i=$((i + 1)); sleep 1
  done
  if [ "$code" != "200" ]; then
    ab_err "smoke server never answered 200 after ${timeout}s (pid $pid); log tail:"
    tail -20 "$log" >&2 || true
    kill "$pid" 2>/dev/null || true
    return 1
  fi
  ab_ok "smoke HTTP $code on http://$host:$port/ after ${i}s"
  # exercise configured paths
  while read -r p; do
    [ -n "$p" ] || continue
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://$host:$port$p" 2>/dev/null || true)
    ab_log "  smoke path $p -> HTTP $code"
    [ "$code" = "200" ] || allok=0
  done < <(ab_config_get '.web.smokePaths // ["/"] | .[]')
  # client-manifest assertion: HTTP 200 alone does not prove the extensions'
  # client bundles reached the boot manifest — an upstream package.json
  # declaration-key change (e.g. dshClient -> dsh.client) silently drops the
  # row from window.__DSH_BOOT__. Check the configured client ids explicitly.
  local cids cid html
  cids=$(ab_config_get '.web.smokeClientIds // [] | .[]')
  if [ -n "$cids" ]; then
    html=$(curl -s --max-time 10 "http://$host:$port/" 2>/dev/null || true)
    for cid in $cids; do
      if printf '%s' "$html" | grep -q "\"id\":\"$cid\""; then
        ab_ok "  client manifest: $cid present"
      else
        ab_err "  client manifest: $cid MISSING (upstream declaration change or extension not attached)"
        allok=0
      fi
    done
  fi
  if [ "$keep" = "1" ]; then
    ab_log "keeping staging server on http://$host:$port (pid $pid, log $log) for manual review"
  else
    # TERM first, then force-free the port (node may drain slowly on SIGTERM)
    kill "$pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 15 ] && lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
      i=$((i + 1)); sleep 1
    done
    if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      ab_warn "  smoke server still on port $port after ${i}s — SIGKILL"
      lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null || true
      sleep 1
    fi
  fi
  [ "$allok" = "1" ]
}
