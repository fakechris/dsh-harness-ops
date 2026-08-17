#!/usr/bin/env node
/**
 * client-bundle-check.mjs — browser-bundle purity check for every web plugin's
 * client bundle. Complements plugin-deps-check.mjs (server-side node_modules
 * integrity): this script scans the BUILT client bundles (package.json
 * `dsh.client` with platform web, or an exports `./client` entry) of every
 * out-of-tree web-profile dependency and flags any leak of Node-only globals
 * into browser code:
 *
 *   process.env   — the dsh-track incident: client.js threw
 *                   "process is not defined" because a build variable was
 *                   baked in as process.env.NODE_ENV
 *   require(      — bare CommonJS require in a browser bundle
 *   __dirname     — Node module path global
 *   __filename    — Node module path global
 *
 * Usage:
 *   node client-bundle-check.mjs [--profile web] [--slot <dir>]
 * Output lines:
 *   ok:    <file>
 *   LEAK:  <file>: <kind> (<snippet>)
 * Exit 0 = no leaks; 1 = at least one leak; 2 = detector failure (unreadable
 * profile manifest), which the caller must report as UNKNOWN.
 */
import { parseArgs } from 'node:util'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { homedir } from 'node:os'

const { values } = parseArgs({
  options: {
    profile: { type: 'string', default: 'web' },
    slot: { type: 'string' },
  },
})
const PROFILE_DIR = values.profile.startsWith('/')
  ? values.profile
  : join(homedir(), '.dsh', 'profiles', values.profile)

function walk(dir, out = []) {
  let entries
  try { entries = readdirSync(dir, { withFileTypes: true }) } catch { return out }
  for (const e of entries) {
    if (e.name === 'node_modules') continue
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (e.name.endsWith('.js') && !p.includes('/types/')) out.push(p)
  }
  return out
}

/** A client bundle exports ./client (lib/client.js) or declares dsh.client. */
function clientBundleFile(packageDir) {
  let manifest
  try {
    manifest = JSON.parse(readFileSync(join(packageDir, 'package.json'), 'utf8'))
  } catch {
    return undefined
  }
  if (manifest.dsh?.client && manifest.dsh.client.platform === 'web') {
    const declared = manifest.dsh.client.bundle
    if (typeof declared === 'string') {
      const path = join(packageDir, declared)
      if (existsSync(path)) return path
    }
  }
  const exportsEntry = manifest.exports?.['./client']
  if (exportsEntry) {
    const file = typeof exportsEntry === 'string'
      ? exportsEntry
      : (exportsEntry.default ?? exportsEntry.import)
    if (typeof file === 'string' && file.endsWith('.js')) {
      const path = join(packageDir, file)
      if (existsSync(path)) return path
    }
  }
  const conventional = join(packageDir, 'lib', 'client.js')
  return existsSync(conventional) ? conventional : undefined
}

const manifest = join(PROFILE_DIR, 'package.json')
let pkg
try { pkg = JSON.parse(readFileSync(manifest, 'utf8')) } catch {
  console.error(`cannot read profile manifest: ${manifest}`)
  process.exit(2)
}

// Node-only patterns. process.env is the incident; the rest are the plan's
// minimum set. Matches are reported with a short snippet for evidence.
const LEAK_PATTERNS = [
  { kind: 'process.env', re: /process\.env\b/g },
  { kind: 'require', re: /(?:^|[^.\w])require\s*\(/g },
  { kind: '__dirname', re: /__dirname\b/g },
  { kind: '__filename', re: /__filename\b/g },
]

let leaks = 0
const seen = new Set()
for (const [depName, spec] of Object.entries(pkg.dependencies ?? {})) {
  let repo
  if (spec.startsWith('link:') || spec.startsWith('file:')) repo = spec.slice(5)
  else continue // registry deps are pnpm-managed, not our bundles
  if (!repo || !existsSync(join(repo, 'package.json'))) continue
  if (seen.has(repo)) continue
  seen.add(repo)
  const bundle = clientBundleFile(repo)
  if (bundle === undefined) continue
  const files = bundle.endsWith('.js') && dirname(bundle).endsWith('lib')
    ? [bundle]
    : walk(bundle.endsWith('.js') ? dirname(bundle) : bundle).filter(f => f.endsWith('.js'))
  for (const file of files) {
    let text
    try { text = readFileSync(file, 'utf8') } catch { continue }
    let hit = false
    for (const { kind, re } of LEAK_PATTERNS) {
      re.lastIndex = 0
      const match = re.exec(text)
      if (match === null) continue
      hit = true
      const start = Math.max(0, match.index - 40)
      const snippet = text.slice(start, match.index + 60).replace(/\s+/g, ' ').trim()
      console.log(`LEAK:  ${file}: ${kind} (...${snippet}...)`)
    }
    if (!hit) console.log(`ok:    ${file} (${depName})`)
    if (hit) leaks += 1
  }
}
process.exit(leaks > 0 ? 1 : 0)
