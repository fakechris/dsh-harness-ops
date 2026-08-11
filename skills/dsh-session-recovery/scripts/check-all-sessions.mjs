#!/usr/bin/env node
/**
 * check-all-sessions.mjs — full-read validation of every session log.
 *
 * Runs persistence.readPrefix() on every log: decodes ALL frames, validates
 * header, torn-record boundaries, seq continuity — the same read the server
 * performs when resuming sessions at startup. Use AFTER a repair to prove the
 * whole store is healthy, and BEFORE restarting the server.
 *
 * Usage:
 *   node check-all-sessions.mjs [--root <sessions-root>]
 * Exit code 0 when all pass, 1 when any fail.
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

let pass = 0
let fail = 0
for (const entry of logs) {
  try {
    const prefix = await persistence.readPrefix(entry.log, entry.id)
    const events = prefix.events
    const last = events[events.length - 1]
    console.log(`OK   ${entry.id}  events=${events.length}  lastSeq=${last ? last.seq : '-'}`)
    pass++
  } catch (error) {
    console.error(`FAIL ${entry.id}: ${error.message}`)
    console.error(`     ${entry.log}`)
    fail++
  }
}
console.log(`\nRESULT: ${pass} pass, ${fail} fail`)
process.exit(fail > 0 ? 1 : 0)
