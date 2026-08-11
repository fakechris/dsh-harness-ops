#!/usr/bin/env node
/**
 * dsh-env — resolve the DSH toolchain from an explicit source checkout.
 *
 * The extension's build/test toolchain (tsc, tsdown, vitest) lives inside a DSH
 * source checkout, and that checkout is the one the extension is compiled and
 * verified AGAINST.  By default that is the live install
 * (`~/.dsh/source/current`); the A/B snapshot rotation (skill dsh-snapshot-ab)
 * points `DSH_SOURCE` at a candidate slot so the extension can be built and
 * tested against the NEXT daily snapshot before any cutover.
 *
 * Usage:
 *   node scripts/dsh-env.mjs --path          print the resolved DSH source
 *   node scripts/dsh-env.mjs <bin> [args…]  spawn <DSH>/node_modules/.bin/<bin>
 */
import { spawnSync } from 'node:child_process'
import { homedir } from 'node:os'
import { join } from 'node:path'

const DSH = process.env.DSH_SOURCE || join(homedir(), '.dsh', 'source', 'current')

const args = process.argv.slice(2)
if (args[0] === '--path') {
  process.stdout.write(DSH + '\n')
  process.exit(0)
}
if (!args[0]) {
  process.stderr.write(`dsh-env: missing <bin> argument (DSH_SOURCE=${DSH})\n`)
  process.exit(2)
}

const bin = args[0]
const binPath = join(DSH, 'node_modules', '.bin', bin)
const result = spawnSync(binPath, args.slice(1), {
  stdio: 'inherit',
  env: { ...process.env, DSH_SOURCE: DSH },
})
process.exit(result.status ?? 1)
