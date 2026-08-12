# dsh-web-doctor — motivation & incident chain (2026-08-11 → 08-12)

> 中文版：[web-doctor-motivation.md](web-doctor-motivation.md)

## Why this exists

On 2026-08-11, three "web won't boot"-related incidents happened on the same machine in one
day; each cost tens of minutes to hours of hands-on recovery. Looking back, **every step was
scriptable** — what was missing was a one-command entry that does NOT depend on the web
process. The doctor fills that gap.

## The incidents (why it hurts)

### Incident 1: web down after the AB switch (08-11 17:49)

- The 0811 snapshot switch succeeded (`current → slot-a`) but the web restart failed; 3080 was
  down ~9 minutes.
- **Root cause A**: the 0811 snapshot **removed `bin/dsh`** (boot moved from the tsx source
  launcher to the compiled `apps/cli/lib/bin.js`); the launcher chain
  `~/.local/bin/dsh → current/bin/dsh` broke.
- **Root cause B (deeper)**: the dsh-track extension gained a `@deepseek-ai/dsh-llm`
  dependency that was missing from the ab-config relink map. **build/test/smoke all green yet
  production failed** — build/test resolve via tsconfig paths / vitest aliases, smoke boots via
  tsx (which also reads tsconfig paths); **only production is pure node ESM (node_modules
  only)**.
- Manual fix: add a `bin/dsh` wrapper + `ln -sfn` dsh-llm.

### Incident 2: the same dsh-llm link wiped externally (08-11 20:44–22:52)

- A manually-`ln`'d link is **unowned** (neither pnpm nor ab.sh manages it); some operation that
  touched `node_modules/@deepseek-ai/` removed it; **no mechanism detected or restored it**
  until the user ran `dsh web` again (22:52) and it failed.

### Incident 3: a session would not open (08-11 night)

- Custom events (`track/sync-preview` etc.) written into session logs by 0810-era dsh-track are
  unknown to the 0811 event whitelist → `SessionFormatUnsupportedError`; 6 old sessions became
  unreadable (official stance: refuse to read rather than misread).

## The manual recovery loop (what cost time)

1. **Read what happened last**: decompress session.jsonl.zstd, look at tail events → "what was
   the system doing before it went down".
2. **Find the root cause**: check web.log / launcher chain / relink existence one by one.
3. **Fix** relinks / add bin/dsh / repair session format.
4. **Relaunch web** + verify HTTP 200.

Every step can be scripted; at the time it was manual commands plus human (or LLM) judgement.

## Key insight: why it must be out-of-band

- **The agent lives inside the web process** — web down means GUI AND agent are both
  unavailable; no "intelligence" is left to help.
- So the rescue tool must be **terminal + local tools only** (node/zstd/jq/curl/ps/lsof), zero
  web dependency.
- But a purely deterministic script has a fatal flaw: **hard-coded rules go stale when DSH
  changes** (0811 deleted `bin/dsh`); new failure modes are unanticipated.

## Why "deterministic + LLM" layers

| Layer | Why needed | Limits |
|---|---|---|
| **Deterministic** (check + fix primitives) | seconds, zero LLM cost, runs when everything is broken; gives the LLM reliable facts and executable actions | rules go stale; new faults unanticipated |
| **LLM brain** (headless one-shot agent) | reads the report + logs and reasons about the root cause; adapts to DSH changes / core incompatibilities / a plugin that scrambled its config | needs the harness itself (compiled packages + credentials) to run; slow, costs tokens |

Live proof of LLM value: on a healthy system it read the report and **independently judged**
the web.log `node: not found` lines as 8/10 history, not the current fault — something a
deterministic rule cannot do (rules only list).

## Evolution (script → full tool in one day)

1. `doctor.sh`: 9 deterministic checks + repair + relaunch (out-of-band by construction).
2. Minimal-dependency layers: L0 self-contained (node built-ins + zstd, no compiled packages) /
   L1 deep, degrades.
3. `dsh-doctor` short PATH entry + slot-bin entry + `--help`.
4. Interactive menu (no args = menu; English default, Chinese switchable).
5. LLM brain `--agent` (headless one-shot + self-heal prompt).
6. Generic plugin coverage `plugin-deps-check` (profile-driven, not ab-config; checks ANY bundle).
7. LLM credential repair (interactive key input / config backup-reset / permission normalize).
8. Honesty pass: skip repair when healthy; classify web.log historical vs current; menu reflects
   real capability.

## Capability and honest boundaries

**Can do automatically**: 9 checks → fix known config faults (relinks / plugin deps / launcher /
sessions / LLM credentials) → LLM reasoning for unknown problems → relaunch web → verify.

**Cannot do (honest)**: the LLM API key itself must come from the user (doctor guides the input
and configures it, never invents one); external causes (key expired/quota) can only be reported;
decisions that need a human (e.g. "should we roll back the slot") are reported clearly, never
acted on silently.

## Related docs

- `skills/dsh-web-doctor/SKILL.md` — user manual (bilingual menu, checks, layers, boundaries)
- `skills/dsh-snapshot-ab/references/postmortem-ab-switch-20260811.md` — full post-mortem of incident 1
- `skills/dsh-session-recovery/SKILL.md` — session repair (incident 3)
