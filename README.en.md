# dsh-harness-ops — DeepSeek Harness Ops Toolbox (self-healing + version rotation)

English | [中文](README.md)

> **This repo is DSH's "ops self-healing toolbox"**: it keeps the harness recovering
> automatically on crash, upgrade, and switchover — no manual intervention. Each of the
> four components owns one job:
>
> | Component | Type | What it does |
> |---|---|---|
> | **`skills/dsh-snapshot-ab`** | skill | Daily upstream-snapshot A/B dual-slot rotation — "switch to the right version" on upgrade |
> | **`skills/dsh-web-guard`** | skill | Self-healing guard — auto-restarts web within 10s of it dying |
> | **`skills/dsh-session-recovery`** | skill | Session-loss diagnosis — locate & losslessly repair "0 sessions" / corrupted logs |
> | **`skills/dsh-web-doctor`** | skill | Out-of-band doctor — one terminal command to diagnose → fix → relaunch when web/A/B are all down |
> | **`plugins/dsh-restart-recover`** | cordis plugin | Restart continuation — an interrupted turn resumes automatically |
>
> Together they answer five questions: **who brings web back up when it dies? Does work
> continue after restart? What if sessions seem lost? How do we switch versions safely
> when the official release arrives? How do we rescue a total A/B outage with one
> command?** They complement each other:
> `ab.sh switch/rollback` kills web → `dsh-web-guard` brings it back → `dsh-restart-recover` continues the turn;
> the last-resort fallback for a total outage is `dsh-web-doctor` (`doctor.sh --fix --restart`).
>
> > Formerly `dsh-skill-snapshot-ab` (renamed 2026-08-11) — the repo grew from a
> > pure AB-rotation skill into a mixed "skill + plugin" toolbox, so the old name no
> > longer fit. The skill directory name `dsh-snapshot-ab` is unchanged (it is the skill
> > trigger name and ab.sh install path; renaming it would break the mechanism).
>
> This README is the **human-readable operations manual** (scenario-based, every command
> included). Agents read each skill's `SKILL.md`.

---

## 📦 Capability map

```
dsh-harness-ops (this repo)
├── skills/dsh-snapshot-ab/        AB rotation: official snapshots in A/B dual slots, old version kept as fallback, atomic switch after acceptance
│   └── scripts/ab.sh              main command (status/discover/notes/prepare/verify/switch/confirm/rollback)
├── skills/dsh-web-guard/          self-healing guard: launchd/systemd hosted, brings web up within 10s of a free port
│   └── scripts/install.sh         cross-platform install (macOS launchd / Linux systemd)
├── skills/dsh-session-recovery/   session-loss diagnosis: 0 sessions/corrupted logs → locate → lossless repair → restart
│   └── scripts/                   validate-sessions / repair-session-log / check-all-sessions / repair-unknown-events
├── skills/dsh-web-doctor/        out-of-band doctor: diagnose → fix → relaunch from the terminal when web/A/B are all down
│   └── scripts/                   doctor.sh / session-last-activity.mjs
└── plugins/dsh-restart-recover/   restart-continuation plugin: detects interrupted on agent/created → auto-injects continuation
    └── src/index.ts               cordis plugin (listens agent/created, zero dsh-track dependency)
```

**The most-used entries**:
- Check status: `$AB status`
- Daily analysis (what did the official change): `$AB discover` / `$AB notes` (official changelog) → see "Scenario C′"
- Daily upgrade: `$AB discover → prepare → switch --yes → confirm`
- Self-heal check: `kill $(lsof -ti :3080)` → auto-restart within 10s → session continues (no manual step)

**Official-change digest (daily analysis)**: the official repo ships **no CHANGELOG**, but it
**requires** an **Agent Note** per non-trivial change (`.agents/notes/implemented/<class>/
yyyy-mm-dd-<topic>.md`, class ∈ feature / bug-fix / simplification / architecture / process /
testing, each with a `.zh.md` + `.i18n.yaml`, format Problem / Decision / Consequences /
Alternatives). So **the notes added between two snapshots ARE the official changelog for that
pair**. `ab.sh discover` (printed automatically when the candidate is newer) and `ab.sh notes`
(standalone) list that changelog directly — read the official "why" first, then verify against
the code diff, and produce `snapshot-diff-report-YYYYMMDD.md`.

---

## 0. Mental model first (AB rotation)

```
~/.local/bin/dsh  (PATH launcher)
   └─> ~/.dsh/source/current   ← symlink pointing at the "currently active" slot
            └─> slot-a/  ── old version (20260809 snapshot + local fix)    ← current production
            └─> slot-b/  ── new version (20260810 snapshot, built+accepted) ← candidate
```

- **Production (http://127.0.0.1:3080) always runs the slot that `current` points to.**
- Switch = one atomic `ln -sfn current <slot>` + restart `dsh web`.
- A/B is a **slot identity** (fixed directory names), the **content rotates daily**: the old
  version occupies one slot, the new snapshot goes into the other slot.
- Both slots can run processes simultaneously (on different ports), but they share
  `~/.dsh`'s sessions/storages — **one production instance stays resident; the other slot is
  used only for acceptance/occasional inspection (read-only, close it after)**, see Scenario E.

Convention: `$AB` below means `~/.dsh/skills/dsh-snapshot-ab/scripts/ab.sh` (present once the skill is installed).

---

## 1. Install

```sh
# One command: 3 skills into ~/.dsh/skills + the dsh-restart-recover bundle
# into the web profile
git clone https://github.com/dsh-external/dsh-harness-ops.git
cd dsh-harness-ops
bash scripts/install.sh

# Optional: self-healing daemon (launchd/systemd, relaunches web ~10s after death)
bash skills/dsh-web-guard/scripts/install.sh

# Configure (auto-read on first run; see skills/dsh-snapshot-ab/references/ab-config.example.json)
#    Usually you only confirm extensions (extension repo paths) and the web port in ab-config.json
vi ~/.dsh/source/ab-config.json

# Verify
$AB status
```

> **Versioning & release**: this repository IS the distribution unit (GitHub is
> the distribution — **no npm publish**, official stance in
> [`docs/RELEASE.md`](docs/RELEASE.md)). Version = root `VERSION` file + git tag
> `vX.Y.Z` + [`CHANGELOG.md`](CHANGELOG.md) (SemVer).
> **Updates need no manual packaging**: `bash scripts/update.sh` does
> `git pull → rebuild plugin lib → reinstall skills/bundle` in one step
> (the bundle plugin ships a `prepare` script, so a git fetch of sources
> rebuilds itself on install).

```sh
# Every update afterwards
cd dsh-harness-ops && bash scripts/update.sh
```

`ab-config.json` key fields: `upstream` (official repo), `extensions[]` (extension list:
repo/relink/build commands), `web.port` (staging smoke port, default 3081),
`web.productionPort` (default 3080), `web.smokeClientIds` (client-manifest assertion),
**`acceptance`** (acceptance switch, below).

### Acceptance mode switch (`acceptance`)

```json
"acceptance": {
  "mode": "manual",                    // "manual" (default; you must confirm before switching) | "auto" (switch once e2e passes)
  "e2e": {
    "enabled": true,                   // requires agent-browser on PATH
    "checks": [ { "id": "@deepseek-ai/dsh-track", "selector": "#dsh-track-fab", "expect": "present" } ]
  }
}
```

- **`e2e`**: opens the candidate in a real browser and asserts these UI elements exist —
  proof that the client plugin **actually renders** (a manifest row ≠ mounted in the browser;
  today's ◆ panel incident is exactly that case).
- **`mode: manual`**: `switch` still requires `--yes` (user confirmation); **`mode: auto`**:
  once e2e passes it counts as user authorization, and `switch` no longer asks for
  interactive confirmation (it still writes handoff and restarts web). Changeable anytime;
  in auto mode `switch` refuses to run if e2e has not passed.

---

## 2. Scenario manual (follow the story; commands are copy-paste ready)

### Scenario A · First deployment: adopt the currently running version as slot-a

> Goal: let the mechanism take over the existing install — the running version becomes slot A,
> mechanism state is persisted. **Does not restart the service.**

```sh
$AB status        # confirm current points where expected, slots empty, phase=idle
$AB init --yes    # create slot-a worktree + pnpm install + full build (build:lib+build:web, a few minutes)
                  # on completion current -> slot-a; the running service is unaffected (new slot takes effect at next restart)
$AB status        # slot a* has content, current=a, phase=idle
```

`init` runs only once. It does a **full build** of the adopted slot (`dsh web` depends on
`lib/` and `apps/web/dist`; a fresh worktree lacks these gitignored artifacts). A build
failure aborts without touching `current`.

### Scenario B · Daily start (the same every day)

```sh
dsh web           # start production. Never specify A/B — it runs the slot `current` points to
```

- The start/restart command is simply `dsh web` (or the PATH launcher), from any directory.
- See which version is running: `readlink ~/.dsh/source/current` or `$AB status`.
- Confirm health: `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3080/` → `200`.

### Scenario C′ · What did the official change → daily analysis (changelog → diff → report)

**Analysis only — never touches the running version.** To learn what a snapshot changed and
what it affects, just say "**analyze today's and yesterday's snapshots** / what did the official
change today / look at today's changelog" in the conversation (equivalent commands below):

```sh
# 1) Official changelog (the "why, and what we gave up") — read this BEFORE the diff
$AB discover               # list snapshot branches; prints the official changelog automatically
                           #   when the candidate is newer (current tip → candidate)
$AB notes                  # standalone: default running tip → newest snapshot; shows the running
                           #   pair when up to date
                           #   --full     print note bodies (Problem/Decision/Consequences/Alternatives)
                           #   --from/--to <ref>   explicit range
                           #   --json     pure JSON (no log lines on stdout)
                           # e.g. feature  2026-08-08-windows-acl-restricted-token-sandbox  —  Windows sandbox rung: ...

# 2) Verify against the code diff (notes are intent, diff is fact; when they disagree,
#    trust the code and report)
#    git diff <old-tip> <new-tip> for deeper dives

# 3) Output: snapshot-diff-report-YYYYMMDD.md (the five change themes + core changes +
#    impact assessment for dsh-track / our usage)
```

**Trigger phrases** (say these in conversation; no CLI needed):

| You say | The agent does |
|---|---|
| "did the official release a new snapshot today" / "look at today's snapshot" | `ab.sh discover` (list snapshots + official changelog when the candidate is newer) |
| "analyze today's and yesterday's snapshots" / "what did the official change today" / "look at today's changelog" | `discover` + `notes` → analyze "notes intent → diff facts" → write the report + impact assessment |
| "run the daily snapshot update" / "upgrade to today's snapshot" | full rotation: `discover → prepare → acceptance → switch → confirm` |
| "switch to the new snapshot" / "AB dual-version rotation" | rotation/rollback flow (write a handoff before restarting web) |

> "what did the official change"-style phrases default to **analysis only**; say "upgrade /
> switch / run daily" to actually rotate.

### Scenario C · Official released a new snapshot → daily rotation (core flow)

> The official ships a new `snapshots/...` branch every day. Goal: **without touching
> production**, build the new snapshot, mount our extensions, accept it, and only then
> switch with your approval.

```sh
# 1) Check status
$AB status                 # who is in production, phase, extension dirty-file count

# 2) See what the official shipped today
$AB discover               # fetch upstream → list snapshot branches → point out the next candidate + diff summary vs current
                           # + official changelog (when the candidate is newer: agent notes added, the official "why")
$AB notes                  # standalone changelog: default running tip → newest; shows the running pair when up to date
                           # --full prints note bodies; --json pure JSON
                           # output like: next candidate: snapshots/20260810T155924Z-8ec407cd64

# 3) Build in the "non-current" slot + mount extensions + smoke (never touches production)
$AB prepare                # auto-picks the non-current slot; can also use explicit --slot b / --snapshot <ref>
                           # pipeline: checkout snapshot → pnpm install --frozen-lockfile
                           #        → build:lib + build:web
                           #        → extension relink + generate tsconfig.ab.json + typecheck/build/test (DSH_SOURCE=candidate slot)
                           #        → extension runtime-deps gate: scan built lib imports vs node_modules,
                           #          fail on missing links (build/test resolve via tsconfig paths / vitest
                           #          aliases and silently hide gaps that production node ESM will hit)
                           #        → auto-materialize a slot launcher wrapper when bin/dsh is absent
                           #          (20260811+ snapshots removed bin/dsh)
                           #        → candidate smoke on staging port (3081), HTTP 200, boot path identical
                           #          to production (pure node ESM, not tsx)
                           # all green → phase=prepared, evidence written to ab-state.json
                           # any step fails → restore extension relink, current untouched, phase back to idle (see Scenario G)

# 4) Re-check (optional)
$AB verify                 # rerun extension tests + smoke against the prepared candidate

# 5) E2E frontend-mount acceptance (recommended — the only step that proves the frontend actually mounted)
$AB e2e                    # open the candidate in a real browser, assert the UI elements in acceptance.e2e.checks exist
                           # (e.g. #dsh-track-fab); on pass, evidence candidateEvidence.e2e.ok=true

# 6) Switch — the mode decides whether this step needs your confirmation (see "acceptance mode")
#    manual mode: $AB switch --yes after your approval
#    auto mode: $AB switch once e2e passes (no interactive confirmation)
$AB switch --yes           # the manual-mode way (auto mode: plain $AB switch)
```

**Three hard rules of `prepare`** (built into the script, but you should know them):
- The candidate slot ≠ the current slot;
- Before `confirm` after a switch, **refuse to recycle the rollback slot** (it is the only
  fallback), unless `--force`;
- Never switch if acceptance has not passed.

### Scenario D · The moment of switch (session breaks; read this first)

> What `switch` does: `current` atomically points to the candidate slot → verify the
> launcher → restart `dsh web`. **Restart = the agent session you are in right now will
> break** (the process hosting web is the one you run in). Expected, not a failure.

**Before switching (3 things)**:
```sh
# ① Finish what you were saying / write a handoff (HANDOFF-snapshot-ab.md in the repo dir is the recovery entry)
# ② Confirm the candidate is prepared and you accepted it
$AB status                 # phase=prepared, candidate=b
# ③ Want to keep the staging inspection instance? Close it first (see Scenario E) to avoid dual instances
```

**Switch**:
```sh
$AB switch --yes
# output shows: CUTOVER → stop old web → start new web (nohup, log ~/.dsh/source/web.log) → HTTP 200
# with dsh-web-guard installed: after ab.sh kills web the guard auto-brings up the new current (fallback, more reliable)
```

**After switching (restart done, open http://127.0.0.1:3080)**:
```sh
# ① Confirm the new version is running
readlink ~/.dsh/source/current          # should = .../slot-b
$AB status                              # current=b, phase=switched, confirmed=false
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3080/   # 200

# ② ⚠️ Hard-refresh the browser (Cmd+Shift+R) — not a normal refresh!
#    Old tabs hold the boot manifest loaded before the switch; new client plugins/panels
#    (e.g. dsh-track's ◆) only appear after refresh. Real pitfall measured 2026-08-11:
#    without refresh, the ◆ FAB never shows up.

# ③ Use it for a few days / a while and confirm the new version is fine
# ④ Fine → mark stable (unlocks recycling the rollback slot the next day)
$AB confirm
```

**Panel (dsh-track) note**: the right panel defaults to **collapsed**; the ◆ FAB at the
bottom-right expands it, and open/close state is kept in browser localStorage
(`dsh.track.open`). If the panel "disappears", check in order: is dsh-track in the manifest →
did you hard-refresh → did you click ◆.

**Finding "the previous session"**: sessions all live on disk (`~/.dsh/sessions/`) and are
re-indexed after restart — none are lost. Find the workspace's historical sessions (e.g.
`~/source/dsh/explorer`) in the GUI; new sessions auto-read that directory's `AGENTS.md` →
`HANDOFF-snapshot-ab.md` and know where to continue.

### Scenario E · Temporarily inspect another version (guarded; don't run bare)

> While production runs, you may want to see the other slot's UI (acceptance / comparison).
> **Don't** run `~/.dsh/source/slot-b/bin/dsh web --port 3081` bare — use `stage`, which
> detects and asks for confirmation.

```sh
$AB stage --slot b --port 3082            # foreground; Ctrl-C to stop
$AB stage --slot a --port 3082 --keep --yes   # background (nohup); stop with the command it prints
```

`stage` behavior:
- **Detects first**: an existing web instance (e.g. production 3080) → prints a warning
  "second instance shares ~/.dsh, read-only view";
- **Requires explicit `--yes`** confirmation before starting; without `--yes` it refuses and exits;
- Target port taken → errors out, telling you to change `--port`;
- `--keep` runs in background and prints the log path and stop command
  (`kill $(lsof -tiTCP:<port> -sTCP:LISTEN)`).

⚠️ During a temporary instance: **read-only**, don't run writes concurrently, close it when done.

### Scenario F · New version has problems → rollback (available anytime)

```sh
$AB rollback --yes     # current points back to lastSwitch.previousTarget (the previous version) + restart web
                       # also breaks the current session; continue from HANDOFF after restart
$AB status             # phase=rolled-back, current back to the old slot
```

After rollback the old version (with local fixes) is fully preserved in the rollback slot;
the new snapshot's problems can be investigated at leisure without affecting production.
Manual fallback (when `ab.sh` is unavailable):
```sh
ln -sfn ~/.dsh/source/slot-a ~/.dsh/source/current
kill <web pid> && cd ~/source/test-fakechris && nohup dsh web &
```

### Scenario G · prepare failed → troubleshoot

Any `prepare` step failure: restores extension relink/tsconfig, leaves `current` untouched,
phase back to `idle`. Locate by output:

| Failed at | Meaning | What to do |
|---|---|---|
| `pnpm install failed` | deps not installed (network/lockfile) | check network; retry `$AB prepare` (auto `clean -fdx` fresh install) |
| `harness build failed` | the new snapshot itself doesn't build | **upstream problem**, don't switch; report the build-output tail to the user/upstream |
| `extension ... FAILED` | our extension is incompatible with the snapshot API (typecheck/build/test red) | this is what acceptance is for: **don't switch**; fix compatibility in the extension repo, rerun prepare |
| `web smoke FAILED` | candidate web won't start / port taken | see smoke log (printed); port taken → change `web.port` |

Retry after a common fix: `$AB prepare` (if the slot is already on the target snapshot with
build artifacts it takes a **reuse fast path**, rerunning only extensions + smoke).

### Scenario H · web won't start / missing build artifacts

Symptoms: `dsh web` starts but the page is blank / complains about missing `lib`, `dist`.
Cause: a new worktree's `lib/` and `apps/web/dist` are gitignored build artifacts —
**`pnpm install` alone is not enough**.
Fix:
```sh
cd ~/.dsh/source/<slot> && pnpm run build     # = build:lib (tsc+tsdown) + build:web (vite)
```
(`ab.sh init` and `ab.sh prepare` both do the full build automatically; only manually
created worktrees need this.)

### Scenario I · Port conflict / dual instance / lock held

```sh
# port taken
lsof -iTCP:3081 -sTCP:LISTEN        # who holds it; stage/smoke → change --port / web.port
# accidentally started a second instance (forgot to close)
lsof -tiTCP:<port> -sTCP:LISTEN | xargs kill
# lock held (another A/B operation in progress)
# → prints "another A/B operation holds the lock"; wait for it to finish, or confirm no zombie and retry
#   lock file: ~/.dsh/source/.ab.lock (flock semantics; python3 fcntl on macOS)
```

### Scenario J · Session "lost" after restart

- Sessions are not lost: `~/.dsh/sessions/` is stored per workspace and re-indexed after
  restart; the GUI sidebar should show all history.
- Still can't see them? Use the in-repo `skills/dsh-session-recovery` skill (the dedicated
  diagnose/repair flow).
- Want to continue from the breakpoint: in a new session say "continue snapshot-ab"; the
  agent loads this skill and reads `HANDOFF-snapshot-ab.md` / `USER-GUIDE-snapshot-ab.md`.

### Scenario K · `current` or the launcher is broken (manual fallback)

```sh
# current missing / pointing wrong
ln -sfn ~/.dsh/source/slot-a ~/.dsh/source/current   # point back at a known-good slot
dsh --version                                        # verify the launcher starts

# dsh on PATH broken
ls -l ~/.local/bin/dsh                               # should -> ~/.dsh/source/current/bin/dsh
ln -sfn ~/.dsh/source/current/bin/dsh ~/.local/bin/dsh
```

---

## 3. Command quick reference

| Command | What it does | What it touches |
|---|---|---|
| `$AB status` | layout/slots/phase/running web/extension dirty files | read-only |
| `$AB discover` | fetch upstream, list snapshots, compute candidate, diff summary; official changelog (added agent notes) when the candidate is newer | fetch only |
| `$AB notes [--from\|--to] [--full] [--json]` | official changelog between two snapshots (agent notes added under `.agents/notes/implemented`; default running tip → newest) | fetch only |
| `$AB init --yes` | adopt the current version as slot-a (worktree+install+**full build**), no restart | current |
| `$AB prepare [--slot a\|b] [--snapshot <ref>] [--skip-web] [--keep] [--force]` | full candidate-slot pipeline (build+extensions+smoke), no production impact | candidate slot only |
| `$AB verify` | rerun extension tests + smoke against the prepared candidate | read-only |
| `$AB e2e [--slot a\|b] [--port N]` | **real-browser frontend-mount acceptance** (agent-browser asserts UI elements in `acceptance.e2e.checks`, e.g. `#dsh-track-fab`); prerequisite for auto-mode switch | temp instance + evidence |
| `$AB stage --slot a\|b [--port N] [--keep]` | temporarily run a slot on a staging port (detects existing instance, requires `--yes`) | temp instance |
| `$AB switch [--yes]` | atomically switch current → candidate + restart web (**breaks session**); manual mode needs `--yes`, auto mode needs e2e passed | current + service |
| `$AB confirm` | mark current stable, unlock recycling the rollback slot next day | state |
| `$AB rollback --yes` | point current back to the previous version + restart web (**breaks session**) | current + service |
| `$AB cleanup [--yes] [dir...]` | list/remove old worktrees (never deletes the current slot) | worktrees |

## 4. Layout and files

| Path | What it is |
|---|---|
| `~/.dsh/source/current` | symlink → currently active slot (production = it) |
| `~/.dsh/source/slot-a` / `slot-b` | the two slots (git worktrees sharing the main clone's object store) |
| `~/source/test-fakechris` | main clone (object store + worktree host, **never a run target**) |
| `~/.dsh/source/ab-state.json` | mechanism state (slots/current/phase/evidence/history) |
| `~/.dsh/source/ab-config.json` | config (upstream/extension list/web ports) |
| `~/.dsh/source/web.log` | production web restart log |
| `~/.dsh/skills/dsh-snapshot-ab/` | this skill (SKILL.md = agent manual, references/ = design + user menu) |

## 5. Design principles (why it is this way)

1. **`current` symlink + git worktree**: isomorphic with the official `dsh-upgrade`; a switch
   is one atomic `ln -sfn`; the main clone is only an object store and worktree host, never run.
2. **Extensions live outside the slots, parameterized by slot**: extensions (e.g. dsh-track)
   point at the target slot via `DSH_SOURCE` / generated `tsconfig.ab.json` / node_modules
   symlinks → they can build and test against the new snapshot **before** the switch.
3. **Acceptance gate**: install / build / extension tests / web smoke all green counts as
   prepared; no acceptance, no switch. Smoke is not just HTTP 200 — `web.smokeClientIds`
   asserts extension clients appear in `window.__DSH_BOOT__` (20260810 changed the declared
   key `dshClient` to `dsh.client`; HTTP-200-only would miss that hole).
4. **Single-instance principle**: the two slots share `~/.dsh` (sessions are append-only
   shared files, storage KV is a single-process serial write chain) — one production
   resident, the other slot only briefly started read-only for `stage`/smoke, closed after.
5. **Confirmation window**: after `switch`, `confirm` is required before the rollback slot
   may be recycled; rollback is always available.
6. **Cooperating with `dsh-web-guard`**: the guard is an "out-of-band" self-healing daemon
   (launchd/systemd hosted, PPID=1, brings web up within 10s of a free port) — after ab.sh
   kills web the guard auto-starts the new current, no manual start needed; if ab.sh itself
   starts successfully the guard doesn't interfere. After switch/restart **hard-refresh the
   browser** to see new client panels.

## 6. Relations with adjacent projects

- Official `dsh-upgrade`: the integration flow that rebases onto upstream master
  (occasionally used); this mechanism is the daily rotation of "official daily snapshot +
  external extensions", and the two coexist.
- **`dsh-web-guard` (another skill in this repo) + `plugins/dsh-restart-recover`**: the
  complete restart self-healing — AB rotation handles "switching to the right version",
  guard (the skill's daemon script) handles "web will definitely come up after restart",
  restart-recover (cordis plugin) handles "the interrupted turn continues automatically
  after restart" (listens to `agent/created`, injects a continuation message, zero user
  input). They complement each other: `ab.sh switch/rollback` kills web → guard brings it
  up → recover continues. The plugin was separated from dsh-track (2026-08-11) because,
  like guard, it is a **platform-level self-healing capability** and should not be bound to
  the business plugin dsh-track.
- **`dsh-session-recovery` (in-repo skill, absorbed 2026-08-11)**: the session-loss
  diagnose/repair/restart flow; incident retrospective at
  `skills/dsh-session-recovery/references/incident-20260809-session-loss.md`.
- Community `mainline-compat` (dsh-external-research): **compatibility monitoring/reporting**
  between plugins and the day's mainline; it answers "can the plugin still be used", this
  mechanism answers "how to switch over safely".
- `dshx-update-check`: commit-SHA comparison **detection** of updates (detection only).

---

## Appendix: measured test log (2026-08-11)

- `init` adopted the old version (be90233) as slot-a, `current` re-pointed, production not
  restarted ✅
- `prepare`+`verify` built the 20260810 snapshot (4cdb149) in slot-b: extension
  typecheck/build/**75 tests all pass**, smoke **HTTP 200** ✅
- The acceptance gate really caught an upstream change: the 20260810 snapshot removed the
  `dsh web --workspace-root` flag (smoke adapted automatically) ✅
- Mechanism bugs fixed: init missing full build (Scenario H), stage missing coexistence
  guardrail (Scenario E), smoke leftover-process cleanup ✅
- **20260810 upstream declared-key rename incident (fixed)**: the snapshot renamed the
  client-modules declared key `dshClient` to `dsh.client`; extensions unadapted → host
  plugin fine, extension tests all green, smoke 200, but the client panel disappeared. Fix:
  extensions uniformly declare the new `dsh.client` key (no compat for old `dshClient`;
  old versions retire with rotation) + acceptance gate gains **client-manifest assertion**
  (`web.smokeClientIds`, parses `__DSH_BOOT__` and validates id by id) ✅
- **Panel regression verification (real browser)**: after the fix, slot-b's `__DSH_BOOT__`
  contains `@deepseek-ai/dsh-track`, `/plugins/.../client.js` 200, plugin apply() executes
  (◆ FAB and panel DOM exist), clicking FAB expands the panel and pulls real data ✅
- **"◆ missing after restart" = old tab not refreshed** (lesson): the boot manifest is read
  at page load; after restart old tabs keep the old manifest; hard refresh (Cmd+Shift+R)
  makes it appear. Written into both skills' verify/troubleshoot sections ✅
