#!/usr/bin/env bash
# acceptance.sh — candidate-slot acceptance gates for the A/B rotation.
# Sourced by ab.sh. Never touches the current/production slot or the running
# server; the candidate is exercised in isolation (its own dir + staging port).
set -euo pipefail

# ---------------------------------------------------------------------------
# Browser token authentication (upstream @deepseek-ai/dsh >= 0.1.5-rc.2)
#
# dsh web now mints a random per-process launch token and prints the root URL
# as `dsh web: http://host:port/?token=<token>`. Only `GET /?token=` mints the
# authority-bound signed cookie; every later request is authenticated by that
# cookie, and a bare `/` (or a stale/wrong-authority cookie) answers 401 before
# RPC dispatch. Upstream documents no loopback exemption and no flag to disable
# it, so a bare GET is no longer a usable liveness probe — which is exactly how
# 0.1.5-rc.2 produced a false-negative smoke (server healthy, gate said failed).
#
# Every probe below therefore: reads the token out of the server's OWN log,
# exchanges it for the cookie with a jar, and follows the 303 to clean `/`. On
# older versions no token is ever printed, so the token stays empty, the jar
# stays unused and the same code path degrades to the plain bare GET it was.
# ---------------------------------------------------------------------------

# ab_web_token_from_log <logfile> — last launch token printed by `dsh web`.
#   Always returns 0: callers run under `set -euo pipefail`, and a log that
#   exists but carries no token (every pre-0.1.5 version) must read as "no
#   token", not as a failure that aborts the gate.
ab_web_token_from_log() {
  local log="$1" tok
  [ -f "$log" ] || return 0
  tok=$(grep -oE '[?&]token=[A-Za-z0-9._~-]+' "$log" 2>/dev/null | tail -1 | sed 's/^[?&]token=//' || true)
  printf '%s' "$tok"
  return 0
}

# ab_web_token_candidates — tokens we could currently authenticate with, best
# source first. Production is started either by ab.sh (web.log) or by the
# launchd guard (its own log, see dsh-web-guard.sh); both are tried because a
# stale token from a previous process must not mask the live one.
ab_web_token_candidates() {
  {
    local l
    while read -r l; do
      [ -n "$l" ] || continue
      ab_web_token_from_log "$l"
    done < <(ab_config_get '.web.authLogs // [] | .[]' 2>/dev/null || true)
    ab_web_token_from_log "$AB_SOURCE/web.log"
    ab_web_token_from_log "/tmp/dsh-web-guard.log"
  } | awk 'NF && !seen[$0]++'
}

# ab_web_tokens_for <log> — which tokens to try for one probe.
#   With <log>: that server ONLY. A staging instance prints its token into the
#   throwaway log we created for it, which no candidate list knows about —
#   looking in production logs there finds nothing and the probe falls back to a
#   bare GET, i.e. a guaranteed 401 against a perfectly healthy server (this is
#   exactly how the first patched smoke still failed).
#   Without <log>: the production logs, since production is started by ab.sh or
#   by the launchd guard and we do not own its stdout here.
ab_web_tokens_for() {
  local log="${1:-}"
  if [ -n "$log" ]; then
    ab_web_token_from_log "$log"
    return 0
  fi
  ab_web_token_candidates
}

# ab_web_get <host> <port> <path> <token> <jar> <outfile> — final HTTP code.
#   -L is required (the token exchange answers 303 to clean `/`) and -c/-b keep
#   the minted cookie across that redirect, which is the point of the jar.
ab_web_get() {
  local host="$1" port="$2" path="$3" tok="$4" jar="$5" out="${6:-/dev/null}" url code
  url="http://$host:$port$path"
  [ -n "$tok" ] && url="$url?token=$tok"
  # a failed connect still prints its own 000 through -w, so drop that output
  # and normalize to one 000 (a bare `|| echo 000` doubles it into "000000").
  code=$(curl -sL -c "$jar" -b "$jar" -o "$out" -w '%{http_code}' --max-time 15 "$url" 2>/dev/null) || code=000
  printf '%s' "${code:-000}"
}

# ab_web_fetch <host> <port> <jar> <bodyfile> [<srclog>] — liveness + body.
#   Tries each applicable token until one authenticates; echoes the code of the
#   last attempt (so a failure reports the real 401 instead of a timeout).
ab_web_fetch() {
  local host="$1" port="$2" jar="$3" body="$4" srclog="${5:-}" tok code=000
  local tokens
  tokens=$(ab_web_tokens_for "$srclog")
  if [ -z "$tokens" ]; then
    ab_web_get "$host" "$port" "/" "" "$jar" "$body"
    return
  fi
  while read -r tok; do
    [ -n "$tok" ] || continue
    code=$(ab_web_get "$host" "$port" "/" "$tok" "$jar" "$body")
    [ "$code" = "200" ] && break
  done <<< "$tokens"
  printf '%s' "$code"
}

# ab_web_wait <host> <port> <timeout> <jar> [<srclog>] — poll until the index is
#   served (200) or the timeout expires. Prints "<code> <seconds>" on ONE line so
#   the caller can read both: a command substitution runs in a subshell, so a
#   variable set in here can never reach the caller.
#     read -r code i <<< "$(ab_web_wait "$host" "$port" "$timeout" "$jar" "$log")"
ab_web_wait() {
  local host="$1" port="$2" timeout="$3" jar="$4" srclog="${5:-}" i=0 code=000
  while [ "$i" -lt "$timeout" ]; do
    code=$(ab_web_fetch "$host" "$port" "$jar" /dev/null "$srclog")
    [ "$code" = "200" ] && break
    i=$((i + 1)); sleep 1
  done
  printf '%s %s' "$code" "$i"
}

# ab_web_body <host> <port> <path> <jar> — authenticated body as CONTENT.
#   Uses the cookie the jar already holds from the root token exchange; the
#   token itself is only valid on `GET /`, so sub-paths authenticate by cookie.
ab_web_body() {
  local host="$1" port="$2" path="$3" jar="$4" f
  f="$(mktemp -t dsh-ab-body.XXXXXX)"
  ab_web_get "$host" "$port" "$path" "" "$jar" "$f" >/dev/null
  cat "$f" 2>/dev/null || true
  rm -f "$f" 2>/dev/null || true
}

# ab_web_kill_port <port> — TERM then force-free a staging port.
#   The nohup'd subshell pid recorded by the boot line is NOT the node pid, so a
#   bare `kill $pid` leaves the server listening (observed: an orphan held 3081
#   after each failed smoke, then broke the next run's port check).
ab_web_kill_port() {
  local port="$1" i=0
  lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs kill -TERM 2>/dev/null || true
  while [ "$i" -lt 15 ] && lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
    i=$((i + 1)); sleep 1
  done
  if lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    ab_warn "  staging server still on port $port after ${i}s — SIGKILL"
    lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null || true
    sleep 1
  fi
}

# acc_e2e <candidate-dir> <port> <host> <timeout>
#   Real-browser E2E: boot the candidate on a staging port, then use
#   agent-browser to verify the configured client plugins' UI is actually
#   attached (e.g. #dsh-track-fab exists — the plugin's apply() ran and the
#   frontend rendered it). This is the "frontend really mounted" gate that
#   manifest grep alone cannot prove. Requires agent-browser on PATH.
acc_e2e() {
  local dir="$1" port="$2" host="$3" timeout="$4"
  local allok=1 pid log i code sel id html jar tok
  command -v agent-browser >/dev/null 2>&1 || { ab_err "e2e: agent-browser not on PATH"; return 1; }
  log="$(mktemp -t dsh-ab-e2e.XXXXXX).log"
  jar="$(mktemp -t dsh-ab-e2e-jar.XXXXXX)"
  ab_log "e2e: booting $(ab_boot_cmd "$dir") web on $host:$port for browser checks (log $log)"
  # shellcheck disable=SC2086
  ( cd "$dir" && nohup $(ab_boot_cmd "$dir") web --port "$port" --host "$host" --no-open >"$log" 2>&1 & echo $! > "$log.pid" )
  pid=$(cat "$log.pid")
  read -r code i <<< "$(ab_web_wait "$host" "$port" "$timeout" "$jar" "$log")"
  if [ "$code" != "200" ]; then
    ab_err "e2e: server never answered 200 (pid $pid, last HTTP $code); log tail:"; tail -15 "$log" >&2 || true
    ab_web_kill_port "$port"
    rm -f "$jar" 2>/dev/null || true
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
    # the root URL must carry the launch token, otherwise the browser lands on
    # the 401 page and every selector check below looks "missing"
    tok=$(ab_web_token_from_log "$log")
    agent-browser open "http://$host:$port/${tok:+?token=$tok}" >/dev/null 2>&1 || true
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
  rm -f "$jar" 2>/dev/null || true
  ab_web_kill_port "$port"
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
  local log pid i code p allok=1 ws_arg iso jar
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
  jar="$(mktemp -t dsh-ab-smoke-jar.XXXXXX)"
  # isolate the second instance's session/storage writes to a throwaway dir so
  # it can never touch the shared ~/.dsh production state (2026-08-21 incident).
  if ! iso="$(ab_stage_isolation_patch)"; then
    ab_err "failed to create staging isolation patch"
    return 1
  fi
  # --workspace-root exists on some snapshots and was removed on others; ask the
  # candidate's own CLI before passing it (acceptance must not assume flags).
  ws_arg=""
  # shellcheck disable=SC2086
  if ( cd "$dir" && $(ab_boot_cmd "$dir") web --help 2>&1 | grep -q -- '--workspace-root' ); then
    ws_arg="--workspace-root $(mktemp -d -t dsh-ab-ws.XXXXXX)"
  else
    ab_warn "  candidate's dsh web has no --workspace-root flag; smoke without it"
  fi
  ab_log "smoke: $(ab_boot_cmd "$dir") --profile web --patch $iso/cordis.patch.yml --port $port (log $log)"
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
  ( cd "$dir" && nohup env $env_prefix $(ab_boot_cmd "$dir") --profile web --patch "$iso/cordis.patch.yml" --no-open --host "$host" --port "$port" $ws_arg >"$log" 2>&1 & echo $! > "$log.pid" )
  pid=$(cat "$log.pid")
  read -r code i <<< "$(ab_web_wait "$host" "$port" "$timeout" "$jar" "$log")"
  if [ "$code" != "200" ]; then
    ab_err "smoke server never answered 200 after ${timeout}s (pid $pid, last HTTP $code); log tail:"
    tail -20 "$log" >&2 || true
    ab_web_kill_port "$port"
    rm -f "$jar" 2>/dev/null || true
    return 1
  fi
  ab_ok "smoke HTTP $code on http://$host:$port/ after ${i}s"
  # exercise configured paths
  while read -r p; do
    [ -n "$p" ] || continue
    # reuse the jar: the root exchange above already minted this authority's cookie
    code=$(ab_web_get "$host" "$port" "$p" "" "$jar" /dev/null)
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
    # `html` holds CONTENT, not a path: fetch through the jar's cookie into a
    # scratch file and read it back (passing "" as the curl -o target would
    # silently produce an empty body and a false MISSING verdict).
    html=$(ab_web_body "$host" "$port" "/" "$jar")
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
    local tk; tk=$(ab_web_token_from_log "$log")
    ab_log "keeping staging server on http://$host:$port (pid $pid, log $log, isolation dir $iso) for manual review"
    [ -n "$tk" ] && ab_log "  authenticated URL for manual review: http://$host:$port/?token=$tk"
  else
    ab_web_kill_port "$port"
    rm -rf "$iso" 2>/dev/null || true
  fi
  rm -f "$jar" 2>/dev/null || true
  [ "$allok" = "1" ]
}
