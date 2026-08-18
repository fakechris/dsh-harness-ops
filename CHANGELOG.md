# Changelog

All notable changes to **dsh-harness-ops** (the DSH ops toolbox: snapshot A/B
rotation + self-healing + session recovery + restart-continue).

Versioning: [SemVer](https://semver.org/). Distribution unit is the GitHub
repository (no npm registry publish required — see `docs/RELEASE.md`).
Each entry links its squash-merged PR.

## [Unreleased]

### dsh-web-doctor structural rewrite (PRs 1–4)

- **Deterministic core** (`scripts/doctor_core.py`): structured `CheckResult`
  (PASS/FAIL/UNKNOWN + severity + evidence + fix_id), 12 detectors (env deps,
  A/B slots + launcher, port, HTTP, browser acceptance, server plugin deps,
  client bundle purity, session files, web.log, credentials chain, settings
  YAML), precise fix mapping (each finding calls only its own fixer),
  fixer-verification by re-running the associated detector, private per-run
  report dirs (`$TMPDIR/dsh-doctor-<uid>-<pid>-<random>/`), and
  HEALTHY/UNVERIFIED/UNHEALTHY aggregation — detector failures are UNKNOWN,
  never PASS.
- **CLI** (`scripts/doctor.py` + thin `doctor.sh`): diagnose / `--diag-json`
  (pure JSON) / `--fix` (safe fixers, each verified, then full refresh) /
  `--fix --restart` / `--fix-item` / `--guide` / `--agent` (headless one-shot
  then full re-check).
- **Browser acceptance** (`scripts/browser-health.mjs`): real headless
  Chromium probe (page errors, error console, plugin load, render); HTTP 200
  alone is never health; probe unavailable → UNKNOWN.
- **Client bundle purity** (`scripts/client-bundle-check.mjs`): flags
  `process.env` / `__dirname` / `__filename` / `require("node:...")` in web
  plugin client bundles (the dsh-track `process is not defined` incident);
  bundler `require()` shims are not false positives.
- **Persistent automation agent** (`scripts/doctor_agent.py`): stdlib JSON-RPC
  client over `dsh --profile automation` (session/prompt / session/cancel /
  shutdown + notifications); one process, one session across turns.
- **Conversation state machine** (`scripts/doctor_controller.py`): orthogonal
  health/agent states; any user message switches to USER_DIRECTED (no keyword
  classifier, no read-only constraint derived from problem counts), cancels a
  running turn via session/cancel on the SAME session, and repairs resolve
  only after re-checking; HEALTHY keeps the surface online.
- **Event-driven TUI** (`scripts/doctor_tui.py`): curses thread only draws and
  reads keys; agent notifications arrive from a worker; terminal sanitization
  (CSI/OSC/DCS/C0 + invalid Unicode), bracketed paste, Ctrl-C interrupts the
  agent not the TUI; no session-log tailing, no blocking I/O in the draw path.
- Tests: 40+ unit/integration/PTY tests including the dsh-track incident
  regression fixture (HTTP 200 + `process is not defined` + failed plugin
  load → probe FAIL naming the plugin and bundle).
- `fix(install)`: production profiles install the published
  `@fakechris/dsh-restart-recover` artifact instead of a local `link:`. This
  keeps `lib/index.js` owned by the installed tarball, so cleaning ignored
  checkout outputs cannot put `dsh web` into a permanent restart loop.

## [0.3.2] — 2026-08-14

**扩展构建链路修复 —— relink 布局兼容。** 轮换到正式版（npm profile 布局）槽位后，
ab-config 的 relink 目标（旧 monorepo 路径 `packages/...` / `vendor/cordis`）在新布局下全部失效，
扩展/插件构建解析 `@deepseek-ai/*` 失败、`update.sh` 卡在插件构建（2026-08-14 实测）。

- `fix(ab)`: relink 解析 layout-aware —— 旧布局路径不存在时回退到
  `<slot>/profiles/node_modules/@deepseek-ai/<pkg>`（pnpm closure），
  `ab_verify_relinks` / `ext_relink` 两处同改，扩展 node_modules 软链在两种布局下都有效。
  ([#61](https://github.com/dsh-external/dsh-harness-ops/pull/61))
- `fix(plugin)`: `plugins/dsh-restart-recover/tsconfig.json` 去掉硬编码的 slot 绝对路径
  （paths/typeRoots 改 `current` 基多布局候选）——构建不再依赖某个具体槽位。
- `fix(update)`: `scripts/update.sh` 解析可用工具链槽位（profile 槽无 dev toolchain）+
  插件构建前自愈 `@deepseek-ai/{cordis,dsh-agent,dsh-session}` 软链。


## [0.3.1] — 2026-08-14

**web-guard 判活修复 + npm 生态轮换 + bundle 发布前整理。** 7 个 PR 自 v0.3.0。

### dsh-web-guard（自愈守护）

- `fix(web-guard)`: 判活改用 `lsof -ti :PORT -sTCP:LISTEN`——旧判定 `lsof -ti :PORT`
  会匹配浏览器侧的连接（远端端口 = PORT），web 死后浏览器页面还挂着时守护会误判
  "端口被占用"而**永不拉起**（2026-08-14 实测：3080 停机 ~20 分钟）。
  ([#59](https://github.com/dsh-external/dsh-harness-ops/pull/59))

### dsh-snapshot-ab（npm 生态轮换）

- `feat(ab)`: npm-ecosystem A/B rotation —— dist-tag upstream（`latest`/`next`），
  npm slot 取代/并存源码快照轮换。([#57](https://github.com/dsh-external/dsh-harness-ops/pull/57))
- `fix(ab)`: npm slots 共享用户数据 —— 切换 npm slot 时 `~/.dsh` 数据（sessions/
  storages/skills）不随槽切换，避免"切槽丢上下文"。([#58](https://github.com/dsh-external/dsh-harness-ops/pull/58))

### bundle 发布准备（`plugins/dsh-restart-recover` → npm）

- `feat(publish)`: 包改名 `@fakechris/dsh-restart-recover`（scope 迁移）。
  ([#55](https://github.com/dsh-external/dsh-harness-ops/pull/55))
- `fix(publish)`: 移除 `private: true`，`publishConfig.access=public` 允许 npm 发布。
  ([#56](https://github.com/dsh-external/dsh-harness-ops/pull/56))

### dsh-web-doctor

- `feat(web-doctor)`: TUI 全量双语 —— 每个 prompt/message/verdict 以主语言 +
  `//` 注记显示另一语言（`DSH_DOCTOR_LANG=en|zh`，默认 en；会话内 `/lang` 切换；
  菜单语言继承入口）。状态栏/标题/输入框语言联动，`/help` 双语。
  ([#53](https://github.com/dsh-external/dsh-harness-ops/pull/53))

## [0.3.0] — 2026-08-13

**mini TUI for dsh-web-doctor** — a real full-screen interactive terminal UI
(human-in-the-loop self-healing), plus the UX/i18n hardening that made it
usable. 7 PRs since v0.2.1.

### mini TUI（`dsh-doctor --guide` / 菜单 5）

- `feat(web-doctor)`: full-screen interactive TUI (python3+curses, stdlib
  only) — status bar + scrollable markdown-rendered pane + bottom input bar.
  Diagnosis STREAMS into the plain terminal first (no black screen), then the
  TUI takes over. ([#46](https://github.com/dsh-external/dsh-harness-ops/pull/46))
- `feat(web-doctor)`: autonomous model — the LLM decides and fixes on its own:
  known issues deterministically auto-fixed, 0 problems → read-only
  auto-acceptance ("✅ 验收通过" + evidence), leftovers → the LLM diagnoses &
  fixes; it only asks the user when it truly cannot decide. The interaction is
  for WATCHING the full CoT (markdown) and Ctrl-C to interrupt & steer.
  ([#47](https://github.com/dsh-external/dsh-harness-ops/pull/47))
- `fix(web-doctor)`: TUI i18n + input editing — UTF-8 locale, wide-char column
  math (CJK renders/cursor/cutoff correct), manual ESC-sequence parsing
  (macOS ncurses splits `ESC[D`; arrows no longer wipe the input), in-line
  cursor editing (←/→/Home/End, ⌫/Delete, insert-at-cursor).
  ([#48](https://github.com/dsh-external/dsh-harness-ops/pull/48))
- `feat(web-doctor)`: live `thinking ⠋` spinner in the status bar while the
  agent runs (web-GUI-style alive indicator). ([#49](https://github.com/dsh-external/dsh-harness-ops/pull/49))
- `feat(web-doctor)`: finish verdict — all green → "✅ 验收通过" + 5s auto-exit
  countdown (any key cancels); problems remain → explicit "keep chatting or
  quit". Never leaves the user at a bare input prompt.
  ([#50](https://github.com/dsh-external/dsh-harness-ops/pull/50))
- `fix(web-doctor)`: menu order — Exit is ALWAYS last (7), Mini TUI → 5,
  Switch language → 6; fixed a latent bug where choosing Mini TUI from the
  menu failed with "run_guided: command not found" (definition order).
  ([#51](https://github.com/dsh-external/dsh-harness-ops/pull/51))
- `fix(web-doctor)`: plugin-deps-check resolves subpath imports via the
  package exports map (e.g. `@deepseek-ai/dsh-client-runtime/client` was
  falsely reported MISSING — a misleading signal that derailed the LLM agent);
  deep-check failure now shows the actual error, diagnose-only exit code 1,
  Ctrl-C kills the agent, self-heal prompt carries a "no rabbit holes"
  discipline. ([#45](https://github.com/dsh-external/dsh-harness-ops/pull/45))
- `docs`: README (bilingual) — full mini-TUI design & usage section; stale
  references fixed (4 skills, current version 0.3.0).

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
