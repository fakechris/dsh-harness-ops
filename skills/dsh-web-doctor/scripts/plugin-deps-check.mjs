#!/usr/bin/env node
/**
 * plugin-deps-check.mjs — GENERIC extension/bundle dependency integrity check.
 *
 * Not tied to ab-config (which only knows dsh-track): it reads a dsh profile
 * (default web), finds every OUT-OF-TREE bundle (dependencies resolved as
 * link:/file:), scans each repo's built lib for bare @deepseek-ai/* / cordis
 * imports, and reports any package missing from that repo's node_modules.
 * For each missing package it also tries to find a matching package dir in
 * the current slot's packages/ tree (by package.json name) — that is the
 * generic fix source (no ab-config mapping needed), covering ANY plugin.
 *
 * Minimal deps: node built-ins + zstd not even needed here (we scan lib/ on
 * disk; the extension's own node_modules is a symlink farm). Out-of-band.
 *
 * Usage:
 *   node plugin-deps-check.mjs [--profile web] [--slot <dir>]
 * Output lines:
 *   ok:      <pkg> (<dep-name>)
 *   FIXABLE: <pkg> (<dep-name>) repo=<repo> -> <slot-package-dir>  # missing; fix source found
 *   MISSING: <pkg> (<dep-name>) repo=<repo>                        # missing; no slot source
 * Exit 0 = all present, 1 = at least one missing (fixable or not).
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
const SLOT = values.slot ?? (() => {
  const c = join(homedir(), '.dsh', 'source', 'current')
  try { return readFileSync(c, 'utf8').trim() } catch { return c }
})()

function walk(dir, out = []) {
  let entries
  try { entries = readdirSync(dir, { withFileTypes: true }) } catch { return out }
  for (const e of entries) {
    if (e.name === 'node_modules') continue
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, out)
    else if (e.name.endsWith('.js') && e.name !== 'client.js' && !p.includes('/types/')) out.push(p)
  }
  return out
}

/**
 * Split an import spec into its base package + optional subpath.
 *   '@deepseek-ai/dsh-x/client'  -> { base: '@deepseek-ai/dsh-x', sub: 'client' }
 *   'cordis'                     -> { base: 'cordis', sub: '' }
 * Subpath imports resolve through the base package (its exports map / files),
 * NOT through a separate node_modules/<full-spec> entry — the naive
 * existsSync(node_modules/<full-spec>) check below used to flag healthy
 * packages as MISSING (e.g. @deepseek-ai/dsh-client-runtime/client, which the
 * package itself exports; that false positive derailed the doctor's LLM agent).
 */
function splitSpec(spec) {
  const parts = spec.split('/')
  if (spec.startsWith('@')) {
    return { base: parts.slice(0, 2).join('/'), sub: parts.slice(2).join('/') }
  }
  return { base: parts[0], sub: parts.slice(1).join('/') }
}

/** Does the base package resolve `sub`? exports map first, then file/dir. */
function subpathResolves(baseDir, sub) {
  if (!sub) return true
  try {
    const pj = JSON.parse(readFileSync(join(baseDir, 'package.json'), 'utf8'))
    const ex = pj.exports
    if (ex && typeof ex === 'object' && !Array.isArray(ex)) {
      const key = './' + sub
      if (key in ex) return true
      // wildcard exports ("./src/*"): the import starts with the prefix
      for (const k of Object.keys(ex)) {
        if (k.endsWith('*') && key.startsWith(k.slice(0, -1)) && key.length > k.length - 1) return true
      }
    }
  } catch { /* unreadable package.json — fall through to direct check */ }
  return existsSync(join(baseDir, sub))
}

/** Find a package dir under slot/packages whose package.json name matches. */
function findSlotPackage(spec) {
  const pkgs = join(SLOT, 'packages')
  const queue = [pkgs]
  while (queue.length) {
    const dir = queue.shift()
    let entries
    try { entries = readdirSync(dir, { withFileTypes: true }) } catch { continue }
    for (const e of entries) {
      const p = join(dir, e.name)
      if (e.isDirectory()) {
        const pj = join(p, 'package.json')
        if (existsSync(pj)) {
          try {
            const d = JSON.parse(readFileSync(pj, 'utf8'))
            if (d.name === spec) return p
          } catch { /* keep walking */ }
        }
        queue.push(p)
      }
    }
  }
  return undefined
}

const IMPORT_RE = /(?:from|import\s*\(\s*|import\s+[^'"]*?from\s+)['"](@deepseek-ai\/[^'"]+|cordis)['"]/g

const manifest = join(PROFILE_DIR, 'package.json')
let pkg
try { pkg = JSON.parse(readFileSync(manifest, 'utf8')) } catch {
  console.error(`cannot read profile manifest: ${manifest}`)
  process.exit(2)
}

let missingAny = 0
const seen = new Set()
for (const [depName, spec] of Object.entries(pkg.dependencies ?? {})) {
  let repo
  if (spec.startsWith('link:') || spec.startsWith('file:')) repo = spec.slice(5)
  else continue // registry deps are managed by pnpm, not our relinks
  if (!repo || !existsSync(join(repo, 'package.json'))) continue
  if (seen.has(repo)) continue
  seen.add(repo)
  const imports = new Set()
  for (const f of walk(repo)) {
    const text = readFileSync(f, 'utf8')
    for (const m of text.matchAll(IMPORT_RE)) imports.add(m[1])
  }
  for (const spec2 of [...imports].sort()) {
    const { base, sub } = splitSpec(spec2)
    const baseDir = join(repo, 'node_modules', base)
    if (existsSync(baseDir) && subpathResolves(baseDir, sub)) {
      console.log(`ok:      ${spec2} (${depName})`)
    } else {
      // missing (base absent, or subpath not resolvable): try to find a fix
      // source for the BASE package — the link must point at the whole package
      // dir, never at a node_modules/<pkg>/<subpath> pseudo-entry.
      const src = findSlotPackage(base)
      if (src) {
        console.log(`FIXABLE: ${spec2} (${depName}) repo=${repo} -> ${src}`)
      } else {
        console.log(`MISSING: ${spec2} (${depName}) repo=${repo}`)
      }
      missingAny = 1
    }
  }
}
process.exit(missingAny)
