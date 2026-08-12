# Changelog

All notable changes to **dsh-harness-ops** (the DSH ops toolbox: snapshot A/B
rotation + self-healing + session recovery + restart-continue).

Versioning: [SemVer](https://semver.org/). Distribution unit is the GitHub
repository (no npm registry publish required — see `docs/RELEASE.md`).
Each entry links its squash-merged PR.

## [0.2.1] — 2026-08-12

Final-release compatibility + web-doctor productization (26 commits since v0.2.0).

- `fix(restart-recover)`: migrate bare `cordis` import to `@deepseek-ai/cordis`
  (import + tsconfig paths + vitest alias; final release's augmentation target).
  ([#37](https://github.com/dsh-external/dsh-harness-ops/pull/37))
- `fix(snapshot-ab)`: `ext_check_runtime_deps` skips client-bundle chunk dir
  (`lib/client/`), not just `client.js` — client-only imports (e.g. dsh-track's
  `@deepseek-ai/dsh-client-runtime/client`) resolve from the profile closure,
  never the relink map. ([#38](https://github.com/dsh-external/dsh-harness-ops/pull/38))
- `feat(web-doctor)`: out-of-band doctor for total web/A-B outages — interactive
  menu, `--agent` headless LLM self-heal, dual entry points, generic plugin
  dependency coverage, bilingual UI, CoT streaming, `--force`. ([#17](https://github.com/dsh-external/dsh-harness-ops/pull/17) [#18](https://github.com/dsh-external/dsh-harness-ops/pull/18) [#19](https://github.com/dsh-external/dsh-harness-ops/pull/19) [#20](https://github.com/dsh-external/dsh-harness-ops/pull/20) [#21](https://github.com/dsh-external/dsh-harness-ops/pull/21) [#22](https://github.com/dsh-external/dsh-harness-ops/pull/22) [#23](https://github.com/dsh-external/dsh-harness-ops/pull/23) [#24](https://github.com/dsh-external/dsh-harness-ops/pull/24) [#25](https://github.com/dsh-external/dsh-harness-ops/pull/25) [#26](https://github.com/dsh-external/dsh-harness-ops/pull/26) [#28](https://github.com/dsh-external/dsh-harness-ops/pull/28) [#29](https://github.com/dsh-external/dsh-harness-ops/pull/29) [#30](https://github.com/dsh-external/dsh-harness-ops/pull/30) [#31](https://github.com/dsh-external/dsh-harness-ops/pull/31) [#32](https://github.com/dsh-external/dsh-harness-ops/pull/32))
- `fix(snapshot-ab+recovery)`: extension relink self-heal on every ab.sh entry +
  `repair-unknown-events.mjs` for session unknown-event refusal (incident
  follow-up). ([#15](https://github.com/dsh-external/dsh-harness-ops/pull/15) [#16](https://github.com/dsh-external/dsh-harness-ops/pull/16))
- `chore/docs`: nested `.worktrees/` convention, productized README intro,
  repo-level AGENTS.md, release reality docs. ([#13](https://github.com/dsh-external/dsh-harness-ops/pull/13) [#14](https://github.com/dsh-external/dsh-harness-ops/pull/14) [#33](https://github.com/dsh-external/dsh-harness-ops/pull/33) [#34](https://github.com/dsh-external/dsh-harness-ops/pull/34) [#35](https://github.com/dsh-external/dsh-harness-ops/pull/35) [#36](https://github.com/dsh-external/dsh-harness-ops/pull/36))

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
