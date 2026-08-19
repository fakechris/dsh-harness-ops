# DSH `dsh-tools` Runtime Drift Runbook

[English](dsh-tools-runtime-repair.md) | [中文](dsh-tools-runtime-repair.zh.md)

This runbook covers a Windows DSH Web deployment started with `npx`, where the Web server may start but a conversation fails with either of the following:

```text
Cannot read properties of undefined (reading 'prepare')
An assistant message with 'tool_calls' must be followed by tool messages
responding to each 'tool_call_id'
```

## Scope and Root Cause

The profile and the running DSH process can load two physical copies of `@deepseek-ai/dsh-tools`. They may have the same package version but are distinct ESM module instances. Their scheduler Symbols differ, the agent loop receives `undefined`, and `undefined.prepare()` fails. A tool call can then be persisted without its matching tool result, which later triggers the provider protocol error.

Do not edit compressed session logs or fabricate tool-result events. A failed historical session may require separate recovery even after the runtime is repaired.

## Six-Phase Procedure

### 1. Feedback loop

Use a brand-new session and request one simple local tool call. Passing means the durable event order is:

```text
tool/call -> tool/result -> turn/end: completed
```

The server returning HTTP 200 is necessary but not sufficient.

### 2. Reproduce and minimize

Read the owning process of port 3080 and its command line:

```powershell
$listener = Get-NetTCPConnection -State Listen -LocalPort 3080
$listener | Select-Object LocalAddress, LocalPort, OwningProcess
Get-CimInstance Win32_Process |
  Where-Object { $_.ProcessId -eq $listener.OwningProcess } |
  Select-Object ProcessId, ParentProcessId, CommandLine | Format-List
```

The command line identifies the active `_npx/<hash>` directory. Compare its `node_modules/@deepseek-ai/dsh-tools` directory with the profile path:

```text
%USERPROFILE%\.dsh\profiles\web\node_modules\@deepseek-ai\dsh-tools
```

### 3. Separate nearby failures

| Error | Meaning | First action |
| --- | --- | --- |
| `.prepare` and missing tool results | runtime drift | relink `dsh-tools` |
| `tool "pwsh" is already registered` | two presets or host/preset both register tools | inspect Web preset composition |
| `EADDRINUSE` | another DSH owns 3080 | inspect the listener PID |
| `Cannot find package` / client registration failure | plugin dependency or client bundle problem | use plugin dependency diagnostics |

### 4. Fix runtime drift

Only replace the profile item if it is a Junction. The target must be the `dsh-tools` directory under the active DSH runtime from step 2.

```powershell
$link = Join-Path $env:USERPROFILE '.dsh\profiles\web\node_modules\@deepseek-ai\dsh-tools'
(Get-Item $link) | Select-Object FullName, LinkType, Target
```

In `cmd.exe`, remove only the Junction and recreate it. Do not use `/s`.

```cmd
rmdir C:\Users\<user>\.dsh\profiles\web\node_modules\@deepseek-ai\dsh-tools
mklink /J C:\Users\<user>\.dsh\profiles\web\node_modules\@deepseek-ai\dsh-tools C:\Users\<user>\AppData\Local\npm-cache\_npx\<active-hash>\node_modules\@deepseek-ai\dsh-tools
```

Compare the runtime Symbol, not only package versions:

```powershell
node --input-type=module -e "import {pathToFileURL} from 'node:url'; const a=await import(pathToFileURL('C:/Users/<user>/.dsh/profiles/web/node_modules/@deepseek-ai/dsh-tools/lib/index.js').href); const b=await import(pathToFileURL('C:/Users/<user>/AppData/Local/npm-cache/_npx/<active-hash>/node_modules/@deepseek-ai/dsh-tools/lib/index.js').href); console.log('sameSymbol='+String(a.TOOL_RUNTIME_SCHEDULER===b.TOOL_RUNTIME_SCHEDULER));"
```

The required result is `sameSymbol=true`.

### 5. Restart and validate

Restart only the confirmed DSH listener. After restart, inspect the new process command line again: `npx` may select a different cache hash, in which case repeat the relink before accepting the restart.

Validate both layers:

```powershell
Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:3080/' | Select-Object StatusCode
```

Expect HTTP 200, then run the new-session tool feedback loop from step 1.

### 6. Prevent recurrence

The `_npx/<hash>` directory is ephemeral. Do not hard-code it in a launcher. After every `npx`-based restart or upgrade, compare the active process runtime path with the profile Junction target. Prefer a fixed, controlled DSH installation/launcher when possible.

### Automated defense (Windows, deployed)

The runbook-level fix has been upgraded to "align before launch" in the Windows guard repo (`dsh-web-guard-win`):

1. **Pre-launch alignment**: `dsh-web-guard.ps1` runs `dsh-tools-sync.ps1` before every `Start-Web`, aligning the profile Junction to the runtime it is about to launch (derived from `$CliJs`, five levels up to `_npx/<hash>`). A new hash selected by the guard is aligned first — there is no window where a new runtime runs against an old Junction.
2. **Post-install sync**: `install.ps1` runs the sync once after install/upgrade, closing the drift window left by `dsh plugin add/update` rewriting `node_modules`.
3. **Standalone repair script**: `dsh-tools-sync.ps1` also runs standalone (diagnosis/verification/manual repair). It resolves the runtime from the 3080 listener PID by default; `-DryRun` previews; exit codes 0/2/3/4/5 are documented in the script header.

The safety rule from step 4 is unchanged: only a Junction is rebuilt automatically (`cmd /c rmdir` + `mklink /J`, non-recursive). A real directory is never touched — warn only. A sync failure is logged and never blocks the guard's relaunch.

One-liner verification against the current runtime:

```powershell
powershell -ExecutionPolicy Bypass -File <dsh-web-guard-win dir>\dsh-tools-sync.ps1
# expect: status=aligned (healthy) / repaired (just fixed); -DryRun previews would-repair
```

## Preset Collision Note

For `pwsh`, `read`, or `glob` “already registered” errors, the Web host tool rows must remain disabled and only one preset should provide the tools. If using a custom `router-standard` preset, set it as the profile default:

```yaml
- id: agent-presets
  config:
    default: router-standard
```

Use `npx @deepseek-ai/dsh --profile web --dump-config` to verify the effective tree.

## Incident Record

Record the time, 3080 PID, DSH runtime path, profile Junction target, `sameSymbol` result, new-session tool event order, old-session status, and all repair actions. This distinguishes runtime drift from a corrupted session or an unrelated plugin failure. Also record the guard log's `dsh-tools-sync exit=` line (0 = aligned/repaired).

