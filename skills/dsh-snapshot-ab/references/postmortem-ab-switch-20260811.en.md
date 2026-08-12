# Post-mortem: A/B snapshot switch incident (2026-08-11 → 08-12)

> Incident: the 20260811 snapshot A/B cutover passed every dry-run gate and was
> declared "safe to restart", yet the production web could not boot after the
> switch. Recovery required manual fixes (a bin/dsh wrapper plus a manual
> dsh-llm relink). ~9 minutes of downtime on port 3080.
> 中文版：[postmortem-ab-switch-20260811.md](postmortem-ab-switch-20260811.md)

---

## 1. Timeline (local time PDT)

| Time | Event |
|---|---|
| 15:57:42 | dsh-track migration PR #29 merged — `src/sync/llm.ts` gains `import @deepseek-ai/dsh-llm`; **ab-config relink NOT updated** |
| 15:55–16:00 | First `ab.sh prepare` (old ab.sh) → **smoke failed**: `nohup: ./bin/dsh: No such file or directory` (the 0811 snapshot removed bin/dsh) |
| 16:00–16:04 | Agent patches ab.sh: PR #8 `ab_boot_cmd` (tsx source boot when bin/dsh is missing) → second prepare all green: 154/154 extension tests, **smoke HTTP 200 (2s)**, client manifest contains dsh-track → phase=prepared |
| 17:47:18 | User approves: "switch" → handoff → 17:47:54 first switch blocked by the `[ -d "$dir/bin" ]` gate |
| 17:48–17:49 | Gate fix (PR #9) → sync ab.sh → 17:49:54 switch retry → **cutover succeeds (current→slot-a)** → web restart fails (`nohup: dsh` / `exec: node: not found`, 11 attempts) → session killed |
| 17:52–17:58 | Post-recovery diagnosis: launcher chain broken (`dsh: command not found`) → manual slot-a/bin/dsh wrapper → `dsh web` reports **`ERR_MODULE_NOT_FOUND: @deepseek-ai/dsh-llm`** → manual `ln -sfn` |
| 17:59:00 | `dsh web` up (pure node `apps/cli/lib/bin.js`), HTTP 200, dsh-track mounted |

---

## 2. Why the dry run was all green yet production failed — root-cause chain

### Root cause 1 (core): module resolution differs across environments — only production is honest

The same `import @deepseek-ai/dsh-llm` is "caught" by a different mechanism at every stage:

| Stage | Resolution mechanism | dsh-llm result |
|---|---|---|
| Extension typecheck/build | tsconfig.json `paths` (dsh-llm → slot packages) | ✅ passes |
| Extension tests (vitest 154/154) | vitest.config.ts `resolve.alias` (dsh-llm → slot packages) | ✅ passes |
| **Web smoke (staging 3081)** | **ab_boot_cmd = tsx boot; tsx reads `TSX_TSCONFIG_PATH` tsconfig paths** (`resolveTsPaths` applies to non-node_modules parents) | ✅ HTTP 200 |
| **Production / manual start** | **pure node ESM (`apps/cli/lib/bin.js`) → node_modules only** | ❌ `ERR_MODULE_NOT_FOUND` |

- The first three environments all resolve **around** node_modules (equivalent to a "link exists" illusion);
- Only production actually checks `dsh-involute/node_modules/@deepseek-ai/dsh-llm`, which the ab-config relink map never listed → boot fails.
- **No prepare step validated extension deps through the production-equivalent resolution path.** The smoke tested the tsx path, not the node-ESM path.

> **One-line root cause**: build/test/smoke module resolution (paths/alias) and production module resolution
> (node_modules symlinks) are two separate worlds; their "package manifests" (tsconfig/vitest paths vs
> ab-config relink) are maintained by hand and out of sync. When an extension adds a dependency, only the
> former gets updated — and the one gate that could pierce the illusion (production-equivalent smoke) did not exist.

### Root cause 2: the launcher chain was outside every gate, masked by a "workaround-style" fix

- `~/.local/bin/dsh → ~/.dsh/source/current/bin/dsh` is a fixed symlink; the 0811 snapshot removed `bin/dsh`, so after cutover current→slot-a had no bin/dsh → **the `dsh` command silently disappeared**.
- The first prepare's smoke **did** catch `./bin/dsh: No such file` — but the fix direction was `ab_boot_cmd` tsx *bypass* (enough for ab.sh's internal start), **not a fix of the launcher chain itself**. Result: ab.sh's own boot survived, while the user/guard `dsh` command stayed broken.
- The switch gate verified `$(ab_boot_cmd) --version` (tsx path), not `dsh --version` (launcher-chain path) → the broken chain passed unnoticed.

### Root cause 3: the restart environment had no node/dsh on PATH

- The 17:49:54 restart failed at the nohup layer: `nohup: dsh: No such file or directory` / `exec: node: not found`.
- ab.sh restart's nohup subshell PATH lacked the node install dir → even without the dependency issue the web could not start.
- (A third, independent trap: the restart PATH assumed a login shell's PATH.)

### Root cause 4 (process): the verification power of the gate list was never examined

"Safe to restart" = all gates green (154/154 + smoke 200 + manifest). But per gate:

| Gate | Verified | NOT verified |
|---|---|---|
| Extension typecheck/build | types/syntax, artifacts | runtime deps availability in node_modules (paths masks it) |
| Extension tests 154/154 | logic correctness | module resolution parity with production (alias masks it) |
| Smoke HTTP 200 + manifest | tsx boot path works, client row present | **pure node ESM boot**, launcher chain, node_modules dep completeness |
| Switch launcher check | `ab_boot_cmd --version` (tsx) | `dsh` (launcher chain) |

**Lesson**: "all green" only means the covered dimensions are green. **No gate covered the "production-equivalent boot path" dimension — the only dimension that matters after cutover.**

---

## 3. Prevention fixes (shipped)

**Mechanism fixes (dsh-harness-ops):**

1. **`ext_check_runtime_deps` (new gate, PR #10)**: prepare scans the extension's built lib for bare `@deepseek-ai/*` / `cordis` imports and fails prepare when any is missing from the extension's node_modules, with a hint to add `extensions[].relink`. The only gate that tsconfig paths / vitest aliases cannot fool.
2. **`ab_boot_cmd` production-path priority (PR #10)**: `bin/dsh` → `apps/cli/lib/bin.js` (pure node ESM) → tsx (last resort). Smoke/e2e/stage/restart all use the production path, so missing links surface at smoke time.
3. **`ab_ensure_slot_launcher` (PR #10)**: prepare materializes a `bin/dsh` wrapper (pointing at `lib/bin.js`) for slots without one; the launcher chain stays valid after every cutover; switch verifies it.
4. **`ab_restart_web` (PR #10)**: falls back to `/opt/homebrew/bin`, `/usr/local/bin` when node is not on the nohup PATH.
5. **`ab.sh confirm` = production acceptance gate (this change)**: confirm now requires four production checks — production port HTTP 200, running web process from the current slot, `dsh` launcher chain resolving inside the current slot, and extension client ids present in the production boot manifest. Any failure refuses the confirm.
6. **`ab_detect_web` / restart process matching (this change)**: matches both launch styles — tsx source and compiled CLI.

**Local config:**
7. `~/.dsh/source/ab-config.json` relink gained `"node_modules/@deepseek-ai/dsh-llm": "packages/llm/llm"`.

**Verified (live):**
- `ext_check_runtime_deps`: link present → pass; temporarily removed → reports exactly `@deepseek-ai/dsh-llm` (exit 1).
- Slot without bin/dsh (with lib/bin.js) → `ab_boot_cmd` uses the compiled entry; `ab_ensure_slot_launcher` is idempotent.
- `ab.sh confirm` refused when the process argv used the `current` symlink form, then passed all four checks after the matcher was fixed, and only then wrote confirmed=true.

---

## 4. Three rules for the future

1. **Acceptance must run the production-equivalent path**: smoke/boot gates must use the same resolution environment as production (pure node ESM + node_modules). More lenient paths (tsx/tsconfig paths) may only be fallbacks, never the only gate. **Confirmation (confirm) must likewise be based on production acceptance.**
2. **The three dependency manifests must stay in sync**: when an extension adds an `@deepseek-ai/*` dependency, update tsconfig paths, vitest alias, and ab-config relink **together**. `ext_check_runtime_deps` blocks the prepare if relink is missed.
3. **A workaround is not a fix**: any "this path fails, so use another path" fix must also verify the original path (e.g. the launcher chain `dsh --version`) still works for users/guards.
