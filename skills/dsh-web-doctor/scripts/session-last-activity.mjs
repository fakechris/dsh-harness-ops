#!/usr/bin/env node
/**
 * session-last-activity.mjs — "what happened last" for the most recently
 * active sessions. Out-of-band (no web process needed): enumerates the
 * session store, sorts by log mtime, and decodes the tail of each recent log
 * to show the last event type/time/seq and a short content hint. Used by
 * dsh-web-doctor to help a human (or a recovery agent) figure out what the
 * system was doing right before it went down.
 *
 * Usage:
 *   node session-last-activity.mjs [--limit N] [--tail N] [--root <sessions-root>]
 */
import { parseArgs } from 'node:util'
import { readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { execFileSync } from 'node:child_process'

const { values } = parseArgs({
  options: {
    limit: { type: 'string', default: '4' },
    tail: { type: 'string', default: '6' },
    root: { type: 'string' },
  },
})
const limit = Number(values.limit)
const tailN = Number(values.tail)
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
      try { const st = statSync(log); out.push({ id: s.name, project: p.name, log, mtime: st.mtimeMs }) } catch { /* plaintext or missing */ }
    }
  }
  return out.sort((a, b) => b.mtime - a.mtime)
}

function decodeTail(log, n) {
  try {
    const plain = execFileSync('zstd', ['-dc', log], { maxBuffer: 1024 * 1024 * 1024 }).toString('utf8')
    const lines = plain.trimEnd().split('\n')
    const tail = lines.slice(-n)
    const events = []
    for (const ln of tail) {
      try {
        const r = JSON.parse(ln)
        // packed chunk rows expand to many events; report the row's type as-is
        events.push({
          type: r.type ?? '?',
          seq: typeof r.seq === 'number' ? r.seq : undefined,
          time: typeof r.time === 'number' ? new Date(r.time).toISOString().slice(11, 19) : undefined,
          hint: hintOf(r),
        })
      } catch { /* skip non-JSON */ }
    }
    return events
  } catch { return [] }
}

function hintOf(r) {
  const t = r.type ?? ''
  if (t === 'user/message') {
    const c = r.data?.content
    const text = Array.isArray(c) ? c.map(x => x?.text ?? '').join(' ') : String(c ?? '')
    return text.slice(0, 80)
  }
  if (t === 'assistant/message' || t === 'assistant/chunk' || t === 'text-chunks') {
    const c = r.data?.content ?? r.data?.text
    const text = Array.isArray(c) ? c.map(x => x?.text ?? '').join(' ') : String(c ?? '')
    return text.slice(0, 80)
  }
  if (t === 'tool/call') {
    const a = r.data?.arguments ?? r.data?.input
    return `tool ${r.data?.name ?? '?'} ${typeof a === 'string' ? a.slice(0, 60) : ''}`
  }
  if (t === 'tool/result') {
    return 'tool result'
  }
  return ''
}

const logs = listLogs().slice(0, limit)
for (const l of logs) {
  const when = new Date(l.mtime).toISOString().replace('T', ' ').slice(0, 19)
  console.log(`${l.id}  (${l.project}, touched ${when})`)
  const evs = decodeTail(l.log, tailN)
  for (const e of evs.reverse()) {
    const seq = e.seq !== undefined ? ` #${e.seq}` : ''
    const tm = e.time ? ` ${e.time}` : ''
    const hint = e.hint ? ` — ${e.hint}` : ''
    console.log(`    ${e.type}${seq}${tm}${hint}`)
  }
}
if (logs.length === 0) console.log('(no zstd session logs found)')
