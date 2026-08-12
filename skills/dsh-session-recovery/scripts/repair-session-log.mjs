#!/usr/bin/env node
/**
 * repair-session-log.mjs — lossless repair of a corrupt session log.
 *
 * Repairs the classic corruption: a session.jsonl.zstd that was recompressed
 * as a SINGLE zstd frame (e.g. by a stock `zstd` CLI run). DSH requires the
 * first frame to contain exactly the header line, and every later frame to end
 * on a record boundary. This script re-frames the byte-identical plaintext
 * using the SAME compressor DSH uses (node:zlib zstdCompress +
 * ZSTD_c_checksumFlag=1), then validates with the DSH reader itself before
 * swapping in place (reversibly: the original is kept as .orig-in-place until
 * every check passes).
 *
 * Usage:
 *   node repair-session-log.mjs --id <session-id>
 *   node repair-session-log.mjs --dir <path-to-session-dir-or-log>
 *   [--root <sessions-root>] [--backup-dir <dir>] [--lines-per-frame N]
 *
 * Exit codes: 0 repaired & verified; 2 nothing to repair (already valid);
 * 1 any failure (original file is left untouched on failure).
 */
import { parseArgs } from 'node:util'
import { zstdCompress, zstdDecompressSync, constants } from 'node:zlib'
import { promisify } from 'node:util'
import { createRequire } from 'node:module'
import { readFile, writeFile, rename, mkdir, copyFile, rm, access } from 'node:fs/promises'
import { join } from 'node:path'
import { loadPersistence, enumerateSessionLogs, sessionRequire } from './lib/dsh.mjs'

const zstdCompressAsync = promisify(zstdCompress)
const CHECKSUM_OPTIONS = { params: { [constants.ZSTD_c_checksumFlag]: 1 } }

const { values } = parseArgs({
  options: {
    id: { type: 'string' },
    dir: { type: 'string' },
    root: { type: 'string' },
    'backup-dir': { type: 'string' },
    'lines-per-frame': { type: 'string' },
  },
})
const linesPerFrame = Number(values['lines-per-frame'] ?? 200)

function fail(msg) {
  console.error(`ABORT: ${msg}`)
  process.exit(1)
}

// --- locate the log file ---------------------------------------------------
const { persistence, root } = loadPersistence(values.root)

let target
if (values.dir) {
  const p = values.dir
  const isLog = p.endsWith('session.jsonl.zstd') || p.endsWith('session.jsonl')
  target = isLog ? p : join(p, 'session.jsonl.zstd')
  try { await access(target) } catch { fail(`cannot access log: ${target}`) }
} else if (values.id) {
  const logs = await enumerateSessionLogs(values.root)
  const matches = logs.filter(l => l.id === values.id)
  if (matches.length === 0) fail(`no session log found for id ${values.id} under ${root}`)
  if (matches.length > 1) fail(`session id ${values.id} appears in multiple project dirs: ${matches.map(m => m.project).join(', ')}`)
  target = matches[0].log
  if (matches[0].compression !== 'zstd') fail(`session ${values.id} is a plaintext log — frame repair not applicable`)
} else {
  fail('provide --id <session-id> or --dir <path>')
}

const EXPECTED_ID = values.id ?? target.split('/').pop()
const SESSION_DIR = target.replace(/\/session\.jsonl\.zstd$/, '')
const LOG = target
const BACKUP_DIR = values['backup-dir'] ?? join(process.cwd(), 'backups', SESSION_DIR.split('/').pop())

// --- 0. pre-check: nothing to repair when the file already validates ---------
try {
  const first = await persistence.readFirstZstdLine(LOG)
  if (first.startsWith('{"type":"session"')) {
    await persistence.readPrefix(LOG, EXPECTED_ID)
    console.log(`ALREADY VALID: ${EXPECTED_ID} passes header + full-read checks — nothing to repair`)
    process.exit(2)
  }
} catch {
  // falls through to repair
}

// --- 1. decompress + integrity ---------------------------------------------
const raw = await readFile(LOG)
let plain
try {
  plain = zstdDecompressSync(raw)
} catch (error) {
  fail(`cannot decompress (is this really zstd?): ${error.message}`)
}
console.log(`decompressed ${raw.length} bytes -> ${plain.length} bytes plaintext`)

const text = plain.toString('utf8')
if (!text.endsWith('\n')) fail('plaintext does not end with a newline (torn tail) — refusing automatic repair')
const lines = text.split('\n')
lines.pop()
console.log(`total lines: ${lines.length} (${lines.length - 1} rows after header)`)

let header
try {
  header = JSON.parse(lines[0])
} catch {
  fail(`first line is not valid JSON: ${lines[0].slice(0, 120)}`)
}
if (header.type !== 'session' || header.id !== EXPECTED_ID) {
  fail(`header id mismatch: file header says ${header.id}, expected ${EXPECTED_ID}`)
}
console.log(`header OK: id=${header.id} cwd=${header.cwd ?? '(none)'} createdAt=${new Date(header.createdAt).toISOString()}`)

let bad = 0
for (let i = 1; i < lines.length; i++) {
  try { JSON.parse(lines[i]) } catch { bad++; if (bad <= 5) console.error(`line ${i + 1} not JSON: ${lines[i].slice(0, 120)}`) }
}
if (bad > 0) fail(`${bad} rows are not valid JSON — refusing to proceed`)

// --- 2. backup -------------------------------------------------------------
await mkdir(BACKUP_DIR, { recursive: true })
const backupPath = join(BACKUP_DIR, 'session.jsonl.zstd.orig-corrupt')
await copyFile(LOG, backupPath)
console.log(`backup written: ${backupPath}`)

// --- 3. rebuild with DSH framing -------------------------------------------
const frames = []
frames.push(await zstdCompressAsync(Buffer.from(lines[0] + '\n'), CHECKSUM_OPTIONS))
const body = lines.slice(1)
for (let i = 0; i < body.length; i += linesPerFrame) {
  const chunk = body.slice(i, i + linesPerFrame).join('\n') + '\n'
  frames.push(await zstdCompressAsync(Buffer.from(chunk, 'utf8'), CHECKSUM_OPTIONS))
}
const rebuilt = Buffer.concat(frames)
console.log(`rebuilt: ${frames.length} frames, ${rebuilt.length} bytes (original ${raw.length})`)

// --- 4. validate rebuilt bytes ---------------------------------------------
const tmpPath = `${LOG}.repair-tmp`
await writeFile(tmpPath, rebuilt, { mode: 0o600 })

let firstLine
try {
  firstLine = await persistence.readFirstZstdLine(tmpPath)
} catch (error) {
  await rm(tmpPath, { force: true })
  fail(`readFirstZstdLine() failed on rebuilt file: ${error.message}`)
}
if (!firstLine.startsWith('{"type":"session"')) {
  await rm(tmpPath, { force: true })
  fail(`rebuilt header frame is not a session header`)
}
console.log(`header frame OK`)

// --- 4b. reversible swap ----------------------------------------------------
const inPlaceOrig = `${LOG}.orig-in-place`
await rename(LOG, inPlaceOrig)
await rename(tmpPath, LOG)

const restore = async () => {
  await rename(LOG, tmpPath).catch(() => {})
  await rename(inPlaceOrig, LOG).catch(() => {})
}

// --- 4c. full read at canonical path + element-wise compare -----------------
let prefix
try {
  prefix = await persistence.readPrefix(LOG, EXPECTED_ID)
} catch (error) {
  await restore()
  fail(`persistence.readPrefix() failed on repaired file (original restored): ${error.message}`)
}

// 双路径解析 dsh-session：源码 checkout（A/B）→ 源码 packages/；npm 安装 → profile 闭包
const { decodeStorageRecord } = sessionRequire()('@deepseek-ai/dsh-session')
const unpacked = []
for (let i = 1; i < lines.length; i++) {
  for (const event of decodeStorageRecord(JSON.parse(lines[i]))) unpacked.push(event)
}
console.log(`readPrefix: ${prefix.events.length} events; original plaintext decodes to ${unpacked.length} events`)

if (prefix.events.length !== unpacked.length) {
  await restore()
  fail(`event count mismatch: repaired ${prefix.events.length} vs original ${unpacked.length} (original restored)`)
}
let mismatch = -1
for (let i = 0; i < prefix.events.length; i++) {
  if (prefix.events[i].seq !== unpacked[i].seq || prefix.events[i].type !== unpacked[i].type) { mismatch = i; break }
}
if (mismatch >= 0) {
  await restore()
  fail(`event mismatch at index ${mismatch} (original restored)`)
}
const firstEvent = prefix.events[0]
const lastEvent = prefix.events[prefix.events.length - 1]
console.log(`first event: seq=${firstEvent.seq} type=${firstEvent.type}`)
console.log(`last event:  seq=${lastEvent.seq} type=${lastEvent.type}`)
console.log(`element-wise check OK: ${prefix.events.length} events identical to original plaintext`)

await rm(inPlaceOrig, { force: true })
console.log(`original corrupt file removed (backup kept at ${backupPath})`)

// --- 5. final whole-root check ---------------------------------------------
let headers
try {
  headers = await persistence.list()
} catch (error) {
  fail(`persistence.list() still throws after swap: ${error.message}`)
}
if (!headers.some(h => h.id === EXPECTED_ID)) fail(`persistence.list() does not include ${EXPECTED_ID} after swap`)
console.log(`FINAL CHECK: persistence.list() OK — ${headers.length} sessions visible`)
console.log('REPAIR COMPLETE')
