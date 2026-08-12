#!/usr/bin/env node
/**
 * session-store-check.mjs — MINIMAL-dependency session store health check.
 *
 * Out-of-band and dependency-light BY DESIGN: uses only node built-ins plus
 * the `zstd` CLI. It does NOT load any DSH compiled package (no
 * @deepseek-ai/dsh-session-persistence-jsonl, no cordis, no extension
 * bundle), so it keeps working when the current slot or its build artifacts
 * are broken — exactly the situation dsh-web-doctor exists for. It checks
 * the FILE layer: every log decodes, its first row is a session header, and
 * its last row parses as JSON. (Full event-vocabulary / seq-continuity
 * checks need the compiled reader; that is the doctor's optional deep layer.)
 *
 * Usage:
 *   node session-store-check.mjs [--root <sessions-root>]
 * Exit 0 when every log is file-healthy, 1 when any is not.
 */
import { parseArgs } from 'node:util'
import { readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { execFileSync } from 'node:child_process'

const { values } = parseArgs({ options: { root: { type: 'string' } } })
const root = values.root ?? join(homedir(), '.dsh', 'sessions')

function listLogs() {
  const out = []
  let projects
  try { projects = readdirSync(root, { withFileTypes: true }) } catch { return out }
  for (const p of projects) {
    if (!p.isDirectory()) continue
    const pdir = join(root, p.name)
    for (const s of readdirSync(pdir, { withFileTypes: true })) {
      if (!s.isDirectory()) continue
      const log = join(pdir, s.name, 'session.jsonl.zstd')
      try { statSync(log); out.push({ id: s.name, log }) } catch { /* skip */ }
    }
  }
  return out
}

function checkLog(log) {
  let plain
  try {
    plain = execFileSync('zstd', ['-dc', log], { maxBuffer: 1024 * 1024 * 1024 })
  } catch (e) {
    return `cannot decode: ${String(e.stderr || e.message).split('\n')[0]}`
  }
  const text = plain.toString('utf8')
  const lines = text.trimEnd().split('\n')
  if (lines.length === 0) return 'empty log'
  let header
  try { header = JSON.parse(lines[0]) } catch { return 'first row is not JSON' }
  if (header.type !== 'session' || typeof header.id !== 'string') return 'first row is not a session header'
  let last
  try { last = JSON.parse(lines[lines.length - 1]) } catch { return 'last row is not JSON (torn tail)' }
  if (typeof last.type !== 'string') return 'last row has no type'
  return null
}

const logs = listLogs()
let ok = 0
const fails = []
for (const l of logs) {
  const problem = checkLog(l.log)
  if (problem) fails.push({ id: l.id, problem })
  else ok++
}
for (const f of fails) console.log(`FAIL ${f.id}: ${f.problem}`)
console.log(`RESULT: ${ok} pass, ${fails.length} fail (of ${logs.length} zstd logs)`)
process.exit(fails.length > 0 ? 1 : 0)
