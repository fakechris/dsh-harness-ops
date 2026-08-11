#!/usr/bin/env node
/**
 * validate-sessions.mjs — per-file header validation.
 *
 * For every session log under the DSH session root, run the SAME first-frame
 * check the server runs inside persistence.list(): the first zstd frame must
 * decompress to exactly one line (the session header). A single failing file
 * makes the real list() throw and hides EVERY session in the GUI.
 *
 * Usage:
 *   node validate-sessions.mjs [--root <sessions-root>]
 * Exit code 0 when all files pass, 1 when any fail.
 */
import { parseArgs } from 'node:util'
import { loadPersistence, enumerateSessionLogs } from './lib/dsh.mjs'

const { values } = parseArgs({
  options: {
    root: { type: 'string' },
  },
})

const { persistence } = loadPersistence(values.root)
const logs = await enumerateSessionLogs(values.root)
if (logs.length === 0) {
  console.log(`no session logs found under ${values.root ?? '~/.dsh/sessions'}`)
  process.exit(0)
}

let pass = 0
let fail = 0
for (const entry of logs) {
  if (entry.compression !== 'zstd') {
    console.log(`SKIP ${entry.id} (plaintext jsonl, no frame check)`)
    pass++
    continue
  }
  try {
    const first = await persistence.readFirstZstdLine(entry.log)
    const header = JSON.parse(first)
    if (header.type !== 'session') throw new Error('first frame is not a session header')
    const ok = header.id === entry.id
    console.log(`${ok ? 'OK  ' : 'BAD '} ${entry.id}  header.id=${header.id} cwd=${header.cwd ?? '-'}${ok ? '' : '  <-- id mismatch with directory name!'}`)
    if (!ok) fail++
    else pass++
  } catch (error) {
    console.error(`FAIL ${entry.id}: ${error.message}`)
    console.error(`     ${entry.log}`)
    fail++
  }
}
console.log(`\nRESULT: ${pass} pass, ${fail} fail`)
process.exit(fail > 0 ? 1 : 0)
