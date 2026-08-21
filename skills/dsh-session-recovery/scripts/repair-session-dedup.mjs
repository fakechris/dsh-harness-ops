#!/usr/bin/env node
/**
 * repair-session-dedup.mjs — lossless repair of a session log corrupted by a
 * DUPLICATED event block (same `seq` appearing twice), which makes the DSH
 * reader throw "corrupt Zstandard session log: complete frame contains a torn
 * JSONL record".
 *
 * Strategy: decode the whole stream to events, drop the SECOND (duplicate)
 * occurrence of any seq that already appeared (keeping the first, which is what
 * the reader commits), then re-frame the corrected rows with DSH's own
 * compressor and validate with the real reader before swapping in place.
 *
 * Usage:
 *   node repair-session-dedup.mjs --id <session-id> [--dry-run]
 *   node repair-session-dedup.mjs --dir <path>     [--dry-run]
 *   [--root <sessions-root>] [--backup-dir <dir>] [--lines-per-frame N]
 *
 * Exit codes: 0 repaired & verified; 2 nothing to repair (already valid);
 * 1 any failure (original file is left untouched on failure).
 */
import { parseArgs } from 'node:util'
import { zstdCompress, zstdDecompressSync, constants } from 'node:zlib'
import { promisify } from 'node:util'
import { readFile, writeFile, rename, mkdir, copyFile, rm, access } from 'node:fs/promises'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadPersistence, enumerateSessionLogs, sessionRequire } from './lib/dsh.mjs'

const zstdCompressAsync = promisify(zstdCompress)
const CHECKSUM_OPTIONS = { params: { [constants.ZSTD_c_checksumFlag]: 1 } }
const ZSTD_MAGIC = 4247762216

const { values } = parseArgs({
  options: {
    id: { type: 'string' },
    dir: { type: 'string' },
    root: { type: 'string' },
    'backup-dir': { type: 'string' },
    'lines-per-frame': { type: 'string' },
    'dry-run': { type: 'boolean', default: false },
  },
})
const linesPerFrame = Number(values['lines-per-frame'] ?? 200)

function fail(msg) {
  console.error(`ABORT: ${msg}`)
  process.exit(1)
}

// --- locate the log file ---------------------------------------------------
const { persistence, root } = loadPersistence(values.root)
const { decodeStorageRecord } = sessionRequire()('@deepseek-ai/dsh-session')

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

// --- 1. scan frames + decode the whole stream ------------------------------
function scanZstdFrames(buffer) {
  const frames = []; let offset = 0
  while (offset < buffer.length) {
    const start = offset
    if (buffer.length - offset < 4) break
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) throw new Error(`corrupt Zstandard session log: invalid frame magic at byte ${offset}`)
    offset += 4
    if (offset === buffer.length) break
    const descriptor = buffer.readUInt8(offset); offset += 1
    if ((descriptor & 24) !== 0) throw new Error(`corrupt Zstandard session log: reserved frame-header bit at byte ${offset - 1}`)
    const contentSizeFlag = descriptor >>> 6
    const singleSegment = (descriptor & 32) !== 0
    const checksum = (descriptor & 4) !== 0
    const dictionaryFlag = descriptor & 3
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag
    const contentSizeBytes = contentSizeFlag === 0 ? singleSegment ? 1 : 0 : 1 << contentSizeFlag
    const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes
    if (buffer.length - offset < remainingHeaderBytes) break
    offset += remainingHeaderBytes
    for (;;) {
      if (buffer.length - offset < 3) break
      const blockHeader = buffer.readUIntLE(offset, 3); offset += 3
      const lastBlock = (blockHeader & 1) !== 0
      const blockType = blockHeader >>> 1 & 3
      const blockSize = blockHeader >>> 3
      if (blockType === 3) throw new Error(`corrupt Zstandard session log: reserved block type at byte ${offset - 3}`)
      const payloadBytes = blockType === 1 ? 1 : blockSize
      if (buffer.length - offset < payloadBytes) break
      offset += payloadBytes
      if (lastBlock) break
    }
    if (checksum) { if (buffer.length - offset < 4) break; offset += 4 }
    frames.push({ start, end: offset })
  }
  return frames
}

const raw = await readFile(LOG)
const frames = scanZstdFrames(raw)
let plain = Buffer.alloc(0)
for (const f of frames) plain = Buffer.concat([plain, zstdDecompressSync(raw.subarray(f.start, f.end))])
const text = plain.toString('utf8')
if (!text.endsWith('\n')) fail('plaintext does not end with a newline (torn tail) — refusing automatic repair')
const lines = text.split('\n'); lines.pop()
console.log(`frames: ${frames.length}; decompressed ${plain.length} bytes -> ${lines.length} rows`)

const header = JSON.parse(lines[0])
if (header.type !== 'session' || header.id !== EXPECTED_ID) {
  fail(`header id mismatch: file header says ${header.id}, expected ${EXPECTED_ID}`)
}
console.log(`header OK: id=${header.id} cwd=${header.cwd ?? '(none)'} createdAt=${new Date(header.createdAt).toISOString()}`)

// --- 2. decode rows, keep first occurrence of each seq ----------------------
const seen = new Set()
let dupRemoved = 0
let totalEvents = 0
let lastSeq = -1
const newRows = [lines[0]]   // header row, byte-identical
for (let r = 1; r < lines.length; r++) {
  let events
  try { events = decodeStorageRecord(JSON.parse(lines[r])) } catch { fail(`row ${r + 1} failed to decode: ${lines[r].slice(0, 120)}`) }
  // Partition this row's events into duplicates (already seen) vs new.
  const keep = []
  let allDup = true
  for (const ev of events) {
    if (seen.has(ev.seq)) { dupRemoved++; continue }
    seen.add(ev.seq); keep.push(ev); allDup = false
  }
  if (allDup) continue                       // whole row was a duplicate — drop it
  if (keep.length === events.length) {
    newRows.push(lines[r])                    // untouched row — keep byte-identical
  } else {
    // Straddling row (part dup, part new): emit the new events as individual rows.
    for (const ev of keep) newRows.push(JSON.stringify(ev))
    console.log(`  split straddling row ${r + 1}: kept ${keep.length} of ${events.length} events`)
  }
  for (const ev of keep) totalEvents++
}

// --- 3. assert the deduped stream is contiguous ----------------------------
for (let i = 0; i < newRows.length - 1; i++) {
  const evs = decodeStorageRecord(JSON.parse(newRows[i + 1]))
  for (const ev of evs) {
    if (ev.seq !== lastSeq + 1) fail(`after dedup, non-contiguous seq: expected ${lastSeq + 1}, got ${ev.seq}`)
    lastSeq = ev.seq
  }
}
if (lastSeq + 1 !== totalEvents) fail(`event count mismatch: contiguous run has seq up to ${lastSeq} (${lastSeq + 1} events) but total ${totalEvents}`)
console.log(`dedup removed ${dupRemoved} duplicate events; contiguous stream: ${totalEvents} events (seq 0..${lastSeq})`)

if (dupRemoved === 0) {
  console.log('no duplicates found — nothing to repair (content already contiguous)')
  process.exit(2)
}

// --- 4. re-frame with DSH framing ------------------------------------------
const rebuiltFrames = []
rebuiltFrames.push(await zstdCompressAsync(Buffer.from(newRows[0] + '\n'), CHECKSUM_OPTIONS))
const body = newRows.slice(1)
for (let i = 0; i < body.length; i += linesPerFrame) {
  const chunk = body.slice(i, i + linesPerFrame).join('\n') + '\n'
  rebuiltFrames.push(await zstdCompressAsync(Buffer.from(chunk, 'utf8'), CHECKSUM_OPTIONS))
}
const rebuilt = Buffer.concat(rebuiltFrames)
console.log(`rebuilt: ${rebuiltFrames.length} frames, ${rebuilt.length} bytes (original ${raw.length})`)

// --- 5. validate rebuilt bytes ---------------------------------------------
const tmpPath = `${LOG}.repair-tmp`
await writeFile(tmpPath, rebuilt, { mode: 0o600 })

// 5a. header frame check (works on any path; no identity requirement).
try {
  const firstLine = await persistence.readFirstZstdLine(tmpPath)
  if (!firstLine.startsWith('{"type":"session"')) fail(`rebuilt header frame is not a session header`)
} catch (error) {
  await rm(tmpPath, { force: true })
  fail(`readFirstZstdLine() failed on rebuilt file: ${error.message}`)
}
console.log('header frame OK')

// 5b. self-check: decode the rebuilt file and assert contiguity/event count.
//     readPrefix() has an identity check that only passes on the canonical
//     path, so for the pre-swap check we decode the frames ourselves.
function decodeFileEvents(path) {
  const buf = readFileSync(path)
  const fs = scanZstdFrames(buf)
  let p = Buffer.alloc(0)
  for (const f of fs) p = Buffer.concat([p, zstdDecompressSync(buf.subarray(f.start, f.end))])
  const ls = p.toString('utf8').split('\n'); ls.pop()
  const evs = []
  for (let r = 1; r < ls.length; r++) evs.push(...decodeStorageRecord(JSON.parse(ls[r])))
  return evs
}
const decodedEvents = decodeFileEvents(tmpPath)
if (decodedEvents.length !== totalEvents) {
  await rm(tmpPath, { force: true })
  fail(`rebuilt decodes to ${decodedEvents.length} events, expected ${totalEvents}`)
}
for (let i = 0; i < decodedEvents.length; i++) {
  if (decodedEvents[i].seq !== i) {
    await rm(tmpPath, { force: true })
    fail(`rebuilt event ${i} has seq ${decodedEvents[i].seq} (non-contiguous)`)
  }
}
console.log(`rebuilt decodes cleanly: ${decodedEvents.length} contiguous events`)

if (values['dry-run']) {
  await rm(tmpPath, { force: true })
  console.log('DRY-RUN: rebuilt file validated; original untouched. To apply, re-run without --dry-run.')
  process.exit(0)
}

// --- 6. backup + reversible swap -------------------------------------------
await mkdir(BACKUP_DIR, { recursive: true })
const backupPath = join(BACKUP_DIR, 'session.jsonl.zstd.orig-corrupt')
await copyFile(LOG, backupPath)
console.log(`backup written: ${backupPath}`)

const inPlaceOrig = `${LOG}.orig-in-place`
await rename(LOG, inPlaceOrig)
await rename(tmpPath, LOG)
const restore = async () => {
  await rename(LOG, tmpPath).catch(() => {})
  await rename(inPlaceOrig, LOG).catch(() => {})
}

// 6c. authoritative validation with the DSH reader on the canonical path.
let prefix
try {
  prefix = await persistence.readPrefix(LOG, EXPECTED_ID)
} catch (error) {
  await restore()
  fail(`persistence.readPrefix() failed on repaired file (original restored): ${error.message}`)
}
if (prefix.events.length !== totalEvents) {
  await restore()
  fail(`reader event count ${prefix.events.length} != expected ${totalEvents} (original restored)`)
}
console.log(`reader accepted repaired file on canonical path: ${prefix.events.length} events`)

await rm(inPlaceOrig, { force: true })
console.log(`original corrupt file removed (backup kept at ${backupPath})`)
console.log('REPAIR COMPLETE')
