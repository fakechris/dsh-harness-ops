#!/usr/bin/env bash
# acceptance.sh — candidate-slot acceptance gates for the A/B rotation.
# Sourced by ab.sh. Never touches the current/production slot or the running
# server; the candidate is exercised in isolation (its own dir + staging port).
set -euo pipefail

# acc_install <candidate-dir>   — pnpm install --frozen-lockfile in the slot
acc_install() {
  local dir="$1"
  ab_log "pnpm install (frozen lockfile) in $dir"
  ( cd "$dir" && pnpm install --frozen-lockfile 2>&1 | tail -5 )
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
  if ( cd "$dir" && ./bin/dsh web --help 2>&1 | grep -q -- '--workspace-root' ); then
    ws_arg="--workspace-root $(mktemp -d -t dsh-ab-ws.XXXXXX)"
  else
    ab_warn "  candidate's dsh web has no --workspace-root flag; smoke without it"
  fi
  ab_log "smoke: $dir/bin/dsh web --port $port (log $log)"
  # shellcheck disable=SC2086
  ( cd "$dir" && nohup ./bin/dsh web --port "$port" --host "$host" $ws_arg >"$log" 2>&1 & echo $! > "$log.pid" )
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
