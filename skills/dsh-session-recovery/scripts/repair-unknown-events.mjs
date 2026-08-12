#!/usr/bin/env node
/**
 * repair-unknown-events.mjs — make a session log loadable again when it
 * contains event types this harness build no longer knows.
 *
 * Background: DSH's coordinator refuses to interpret a log containing an
 * event type outside KNOWN_SESSION_EVENT_TYPES unless that event carries the
 * envelope's `ignorable: true` marker — the official vocabulary-growth
 * channel (SessionEvent.ignorable). The 2026-08-11 snapshot removed the
 * dsh-track custom events (`track/sync-preview`, `track/decision`), so
 * sessions written by the 0810 snapshot fail to load with
 * SessionFormatUnsupportedError ("unknown to this harness and not marked
 * ignorable").
 *
 * This script adds that single marker to every top-level storage record that
 * is a full event ENVELOPE (type+seq+time+data) outside the known set and
 * not already marked ignorable. Packed-chunk rows (text-chunks /
 * tool-call-chunks / reasoning-chunks …) are storage-layer batch encodings,
 * not events — they are never touched. Conversation content is otherwise
 * byte-identical: frames that contain no target event are kept verbatim;
 * only frames that do are recompressed with DSH's own frame compressor, so
 * the frame structure stays exactly as DSH wrote it (a from-scratch
 * re-framing of the plaintext is NOT equivalent and trips the torn-record
 * check — verified 2026-08-12).
 *
 * Usage:
 *   node repair-unknown-events.mjs --id <session-id>
 *   node repair-unknown-events.mjs --dir <path-to-session-dir-or-log>
 *   node repair-unknown-events.mjs --all            # every affected session
 *   [--root <sessions-root>] [--backup-dir <dir>] [--dry-run]
 *
 * Exit codes: 0 repaired/verified; 2 nothing to fix; 1 any failure
 * (original files are left untouched on failure).
 */
import { parseArgs } from 'node:util'
import { zstdCompress, zstdDecompress, constants } from 'node:zlib'
import { promisify } from 'node:util'
import { readFile, writeFile, rename, mkdir, copyFile, rm } from 'node:fs/promises'
import { join } from 'node:path'
import { loadPersistence, enumerateSessionLogs, sessionRequire } from './lib/dsh.mjs'

const zstdCompressAsync = promisify(zstdCompress)
const zstdDecompressAsync = promisify(zstdDecompress)
const CHECKSUM_OPTIONS = { params: { [constants.ZSTD_c_checksumFlag]: 1 } }
const ZSTD_MAGIC = 0xfd2fb528

/**
 * Scan complete zstd frames (same algorithm as the DSH backend
 * session-persistence-jsonl scanZstdFrames): parse each frame's header and
 * blocks precisely, so node:zlib-encoded frames are handled identically.
 */
function scanZstdFrames(buffer) {
  const frames = []
  let offset = 0
  while (offset < buffer.length) {
    const start = offset
    if (buffer.length - offset < 4) return { frames, tornStart: start }
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) throw new Error(`invalid frame magic at byte ${offset}`)
    offset += 4
    if (offset === buffer.length) return { frames, tornStart: start }
    const descriptor = buffer.readUInt8(offset)
    offset += 1
    if ((descriptor & 24) !== 0) throw new Error(`reserved frame-header bit at byte ${offset - 1}`)
    const contentSizeFlag = descriptor >>> 6
    const singleSegment = (descriptor & 32) !== 0
    const checksum = (descriptor & 4) !== 0
    const dictionaryFlag = descriptor & 3
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag
    const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : 1 << contentSizeFlag
    const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes
    if (buffer.length - offset < remainingHeaderBytes) return { frames, tornStart: start }
    offset += remainingHeaderBytes
    for (;;) {
      if (buffer.length - offset < 3) return { frames, tornStart: start }
      const blockHeader = buffer.readUIntLE(offset, 3)
      offset += 3
      const lastBlock = (blockHeader & 1) !== 0
      const blockType = blockHeader >>> 1 & 3
      const blockSize = blockHeader >>> 3
      if (blockType === 3) throw new Error(`reserved block type at byte ${offset - 3}`)
      const payloadBytes = blockType === 1 ? 1 : blockSize
      if (buffer.length - offset < payloadBytes) return { frames, tornStart: start }
      offset += payloadBytes
      if (lastBlock) break
    }
    if (checksum) {
      if (buffer.length - offset < 4) return { frames, tornStart: start }
      offset += 4
    }
    frames.push({ start, end: offset })
  }
  return { frames }
}

const { values } = parseArgs({
  options: {
    id: { type: 'string' },
    dir: { type: 'string' },
    all: { type: 'boolean', default: false },
    root: { type: 'string' },
    'backup-dir': { type: 'string' },
    'dry-run': { type: 'boolean', default: false },
  },
})
const dryRun = values['dry-run'] === true

function fail(msg) {
  console.error(`ABORT: ${msg}`)
  process.exit(1)
}

const { persistence, root } = loadPersistence(values.root)
const sessionRequireFn = sessionRequire()
const { KNOWN_SESSION_EVENT_TYPES, decodeStorageRecord } = sessionRequireFn('@deepseek-ai/dsh-session')

// --- locate targets ----------------------------------------------------------
let targets = []
if (values.dir) {
  const p = values.dir
  const isLog = p.endsWith('session.jsonl.zstd') || p.endsWith('session.jsonl')
  targets = [{ id: p.split('/').pop().replace(/^session\.jsonl.*$/, '') || p.split('/').slice(-2)[0], log: isLog ? p : join(p, 'session.jsonl.zstd'), project: '' }]
} else if (values.id) {
  const logs = await enumerateSessionLogs(values.root)
  const matches = logs.filter(l => l.id === values.id)
  if (matches.length === 0) fail(`no session log found for id ${values.id} under ${root}`)
  targets = matches
} else if (values.all) {
  targets = await enumerateSessionLogs(values.root)
} else {
  fail('provide --id <session-id>, --dir <path>, or --all')
}

let fixed = 0, skipped = 0
for (const t of targets) {
  const id = t.id
  const LOG = t.log
  const SESSION_DIR = LOG.replace(/\/session\.jsonl\.zstd$/, '')
  const BACKUP_DIR = values['backup-dir'] ?? join(process.cwd(), 'backups', SESSION_DIR.split('/').pop())
  console.log(`\n=== ${id} (${LOG}) ===`)

  // --- 0. pre-check: does the current build already accept this log? ----------
  // `readFrom(id, 0)` is the coordinator path the GUI uses to load history —
  // it runs assertEventsSupported (readPrefix/loadStored only check framing,
  // so they would wrongly report "already loads" for an unknown-event log).
  let alreadyValid = false
  try {
    const first = await persistence.readFirstZstdLine(LOG)
    if (first.startsWith('{"type":"session"')) {
      await persistence.readFrom(id, 0)
      alreadyValid = true
    }
  } catch { /* falls through to repair */ }
  if (alreadyValid) {
    console.log(`  OK: already loads on this build — nothing to fix`)
    skipped++
    continue
  }

  // --- 1. read + scan frames ---------------------------------------------------
  const raw = await readFile(LOG)
  let frames
  try {
    frames = scanZstdFrames(raw).frames
  } catch (error) {
    fail(`cannot parse zstd frames of ${LOG}: ${error.message}`)
  }
  if (frames.length === 0) fail(`no zstd frames in ${LOG}`)

  // --- 2. find unknown-type events, rebuild frame by frame ---------------------
  const marked = []
  const out = []
  let headerSeen = false
  for (let i = 0; i < frames.length; i++) {
    const f = frames[i]
    let dec
    try {
      dec = await zstdDecompressAsync(raw.subarray(f.start, f.end))
    } catch (error) {
      fail(`cannot decompress frame ${i} of ${LOG}: ${error.message}`)
    }
    const text = dec.toString('utf8')
    if (!text.endsWith('\n')) fail(`frame ${i} of ${LOG} does not end on a record boundary — refusing automatic repair`)
    const lines = text.slice(0, -1).split('\n')
    let dirty = false
    const newLines = lines.map((ln, li) => {
      // line 0 of frame 0 is the session header — never an event
      if (i === 0 && li === 0) return ln
      let r
      try { r = JSON.parse(ln) } catch { return ln }
      const isEventEnvelope = r && typeof r === 'object'
        && typeof r.type === 'string' && typeof r.seq === 'number'
        && typeof r.time === 'number' && r.data !== undefined
      if (isEventEnvelope && !KNOWN_SESSION_EVENT_TYPES.has(r.type) && r.ignorable !== true) {
        marked.push({ type: r.type, seq: r.seq })
        dirty = true
        return JSON.stringify({ ...r, ignorable: true })
      }
      return ln
    })
    if (i === 0) {
      const h = JSON.parse(lines[0])
      if (h.type !== 'session' || h.id !== id) fail(`header id mismatch: ${h.id} != ${id}`)
      headerSeen = true
    }
    if (dirty) {
      out.push(await zstdCompressAsync(Buffer.from(newLines.join('\n') + '\n'), CHECKSUM_OPTIONS))
    } else {
      out.push(raw.subarray(f.start, f.end))
    }
  }
  if (!headerSeen) fail(`no session header in ${LOG}`)
  if (marked.length === 0) {
    console.log(`  no unknown-type events found (log fails for another reason) — leaving untouched`)
    skipped++
    continue
  }
  console.log(`  marking ${marked.length} unknown event(s) ignorable:`)
  for (const m of marked) console.log(`    type=${m.type} seq=${m.seq}`)

  if (dryRun) {
    console.log(`  [dry-run] would rewrite ${marked.length} record(s) — no writes performed`)
    continue
  }

  // --- 3. baseline: what the READER sees today (before any write) --------------
  // readPrefix does not run assertEventsSupported, so the original log reads
  // fine — capture its events to prove the repair changes nothing beyond the
  // ignorable markers. (NB: the reader may legitimately emit fewer events than
  // the raw plaintext decodes — e.g. a torn tail or a filtered legacy row —
  // so the correct comparison is reader-vs-reader, not reader-vs-plaintext.)
  let origPrefix
  try {
    origPrefix = await persistence.readPrefix(LOG, id)
  } catch (error) {
    fail(`cannot read original prefix for baseline: ${error.message}`)
  }

  // --- 4. backup ----------------------------------------------------------------
  await mkdir(BACKUP_DIR, { recursive: true })
  const backupPath = join(BACKUP_DIR, 'session.jsonl.zstd.orig-unknown-events')
  await copyFile(LOG, backupPath)
  console.log(`  backup: ${backupPath}`)

  // --- 4. write rebuilt bytes + validate ----------------------------------------
  const rebuilt = Buffer.concat(out)
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
    fail('rebuilt header frame is not a session header')
  }

  // --- 5. reversible swap, then full validation on the CANONICAL path -----------
  // (readPrefix/readFrom assert path identity against the header, so a temp
  // path can never pass them — validation must run after the swap.)
  const inPlaceOrig = `${LOG}.orig-in-place`
  await rename(LOG, inPlaceOrig)
  await rename(tmpPath, LOG)
  const restore = async () => {
    await rename(LOG, tmpPath).catch(() => {})
    await rename(inPlaceOrig, LOG).catch(() => {})
  }

  let prefix
  try {
    prefix = await persistence.readPrefix(LOG, id)
  } catch (error) {
    await restore()
    fail(`readPrefix() still fails after marker (original restored): ${error.message}`)
  }
  // the GUI history path must also accept it: readFrom runs assertEventsSupported
  try {
    await persistence.readFrom(id, 0)
  } catch (error) {
    await restore()
    fail(`readFrom() still refuses the log after marker (original restored): ${error.message}`)
  }
  console.log(`  readFrom() (GUI history path) accepts the repaired log`)

  // element-wise compare against the PRE-REPAIR reader result: every event's
  // seq/type must match; the only allowed difference is the ignorable marker.
  if (prefix.events.length !== origPrefix.events.length) {
    await restore()
    fail(`event count mismatch: repaired ${prefix.events.length} vs pre-repair reader ${origPrefix.events.length} (original restored)`)
  }
  let mismatch = -1
  for (let i = 0; i < prefix.events.length; i++) {
    const a = prefix.events[i], b = origPrefix.events[i]
    if (a.seq !== b.seq || a.type !== b.type) { mismatch = i; break }
  }
  if (mismatch >= 0) {
    await restore()
    fail(`event mismatch at index ${mismatch} (original restored)`)
  }
  await rm(inPlaceOrig, { force: true })
  console.log(`  REPAIRED: ${prefix.events.length} events identical (seq/type) to original; log now loads`)
  fixed++
}

// --- 6. final whole-root check --------------------------------------------------
let headers
try {
  headers = await persistence.list()
} catch (error) {
  fail(`persistence.list() still throws after repair: ${error.message}`)
}
console.log(`\nFINAL CHECK: persistence.list() OK — ${headers.length} sessions visible`)
console.log(dryRun ? `DRY RUN: ${fixed} repaired / ${skipped} already-ok (no writes)` : `DONE: ${fixed} repaired / ${skipped} already-ok`)
process.exit(fixed > 0 ? 0 : 2)
