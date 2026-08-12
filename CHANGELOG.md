# Changelog

All notable changes to **dsh-harness-ops** (the DSH ops toolbox: snapshot A/B
rotation + self-healing + session recovery + restart-continue).

Versioning: [SemVer](https://semver.org/). Distribution unit is the GitHub
repository (no npm registry publish required — see `docs/RELEASE.md`).
Each entry links its squash-merged PR.

## [0.2.0] — 2026-08-12

Switch-incident hardening (post-mortem: `skills/dsh-snapshot-ab/references/postmortem-ab-switch-20260811.md`).

- `fix(snapshot-ab)`: prepare catches extension runtime-deps + keeps launcher
  chain alive — new `ext_check_runtime_deps` gate, production-path boot order
  (`lib/bin.js` before tsx), slot launcher materialization, restart node PATH
  fallback. ([#10](https://github.com/dsh-external/dsh-harness-ops/pull/10))
- `fix(snapshot-ab)`: confirm = production acceptance gate — confirm now
  requires live production checks (HTTP 200 / process from current slot /
  launcher chain / client manifest); `ab_detect_web` matches compiled-CLI
  processes; bilingual post-mortem shipped. ([#11](https://github.com/dsh-external/dsh-harness-ops/pull/11))
- `chore(release)`: release process — `VERSION` + git tags + `scripts/install.sh`
  + `scripts/update.sh` + `docs/RELEASE.md`.

## [0.1.0] — 2026-08-11

Initial toolbox.

- `skills/dsh-snapshot-ab` — official daily snapshot A/B dual-slot rotation
  (discover/notes/prepare/verify/e2e/switch/confirm/rollback; changelog via
  official agent notes).
- `skills/dsh-web-guard` — self-healing daemon (launchd/systemd), relaunches
  dsh web ~10s after death.
- `skills/dsh-session-recovery` — session-loss diagnosis & lossless repair
  (0 sessions / corrupt zstd logs).
- `plugins/dsh-restart-recover` — cordis bundle: auto-continue of an
  interrupted agent turn after a restart.
