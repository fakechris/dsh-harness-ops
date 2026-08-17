#!/usr/bin/env bash
# dsh-web-doctor — OUT-OF-BAND diagnosis, repair and relaunch for dsh web.
#
# Thin compatibility entry (2026-08-17): all logic lives in the deterministic
# Python core (doctor.py + doctor_core.py + browser-health.mjs +
# client-bundle-check.mjs). Use this when the web (3080) is down or won't boot
# — including when BOTH A/B slots are broken. It runs entirely from the
# terminal with local tools (node/zstd/jq/curl/ps/lsof/python3); it does NOT
# depend on a running web process.
#
# USER-FIRST: run `dsh-doctor` with NO arguments → a read-only structured
# report. `dsh-doctor --guide` → the interactive mini TUI (you confirm every
# fix step; no unattended long runs unless you explicitly choose the LLM step).
#
# Flag mode (for scripts / advanced use):
#   dsh-doctor                 # diagnose only (read-only)
#   dsh-doctor --fix           # diagnose + deterministic auto-fix (safe fixers)
#   dsh-doctor --fix --restart # diagnose + fix + relaunch web
#   dsh-doctor --agent         # diagnose + LLM brain (headless one-shot) + re-check
#   dsh-doctor --guide         # mini TUI — human-guided, step-by-step
#   dsh-doctor --diag-json     # structured PASS/FAIL/UNKNOWN JSON on stdout
#   dsh-doctor --fix-item <id> # run exactly one fixer (credentials may prompt)
#   dsh-doctor --quiet         # less chatter
#
# Exit codes: 0 all-clear (or fixed+verified); 1 diagnosis found problems;
# 2 web not up after restart. Safe to re-run; every fix is verified by
# re-running the detector that flagged it.
exec python3 "$(dirname "$0")/doctor.py" "$@"
