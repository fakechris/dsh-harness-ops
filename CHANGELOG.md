# Changelog

All notable changes to **dsh-harness-ops** (the DSH ops toolbox: snapshot A/B
rotation + self-healing + session recovery + restart-continue).

Versioning: [SemVer](https://semver.org/). Distribution unit is the GitHub
repository (no npm registry publish required — see `docs/RELEASE.md`).
Each entry links its squash-merged PR.

## [Unreleased]

- `fix(web-doctor)`: menu order — Exit is ALWAYS the last option (7), Mini TUI
  moved to 5 and Switch language to 6; Mini TUI menu copy updated to the
  current autonomous model (was stale "per-step confirmation" wording). Also
  fixed a latent bug: run_guided was defined AFTER the entry-point dispatch,
  so choosing Mini TUI from the menu failed with "command not found" (the
  --guide flag path worked, the menu path did not).


- `feat(web-doctor)`: TUI finish verdict — when the LLM agent finishes, the
  TUI never leaves the user guessing at a bare input prompt: 0 problems + web
  up → "✅ 验收通过：web 正常、无残留问题" + a 5s auto-exit countdown (any key
  cancels and lets you keep chatting); problems remain → "⚠ N 个问题未解决" +
  explicit "keep chatting or q to quit". Agent-done state also shows a live
  'thinking' spinner in the status bar (web-GUI-style alive indicator).


- `fix(web-doctor)`: TUI i18n + input editing — Chinese (CJK) input & editing
  works: UTF-8 locale set before curses (get_wch returned CJK byte-wise
  before), wide-char column math (display_width/trunc_width) so CJK renders
  and cursor/cutoff never misalign, manual ESC-sequence parsing (macOS ncurses
  delivers `ESC[D` as separate chars even with keypad on — arrows were read as
  ESC and the old handler WIPED the input), input cursor editing (←/→/Home/
  End move, ⌫/Delete delete at cursor, insert at cursor), and lone ESC is a
  no-op instead of clearing the message.


- `feat(web-doctor)`: mini TUI guided mode (`dsh-doctor --guide` / menu 7) — a
  REAL full-screen interactive TUI (python3+curses, stdlib only). The
  deterministic diagnosis STREAMS into the plain terminal first (no black
  screen), then the TUI takes over: status bar + scrollable markdown-rendered
  pane + bottom input bar. **The LLM decides and fixes autonomously**: known
  issues auto-fixed deterministically (no per-item confirmation), 0 problems →
  read-only auto-acceptance ("✅ accepted" + evidence), leftovers → the LLM
  diagnoses & fixes on its own; it only asks the user when it truly cannot
  decide. The interaction is for WATCHING the full CoT (markdown rendering:
  headings/bold/inline code/fences/lists/quotes) and **Ctrl-C to interrupt &
  steer** the agent mid-run (context carried across turns). Falls back to a
  step-by-step non-TTY mode when no terminal. Lesson from 2026-08-13: an
  unattended `--agent` run once burned its whole timeout on noise, fixing
  nothing — no unattended long run by default.
- `fix(web-doctor)`: `plugin-deps-check` resolves subpath imports via the
  package's exports map (e.g. `@deepseek-ai/dsh-client-runtime/client` was
  falsely reported MISSING — a misleading signal that derailed the LLM agent).
- `fix(web-doctor)`: deep-check failure now shows the actual error and is
  labelled environment noise, not "current slot may be broken"; `--agent` runs
  get a Ctrl-C trap that kills the agent, and the self-heal prompt carries a
  "no rabbit holes" discipline; diagnose-only exit code now 1 when problems are
  found (matching the documented contract).

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
