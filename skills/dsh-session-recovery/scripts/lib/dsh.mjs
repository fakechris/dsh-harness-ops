/**
 * Shared helpers: resolve the DSH session persistence backend and load it
 * exactly as the running `dsh web` server uses it, across all install modes:
 *
 *  - source checkout (A/B snapshots): `$DSH_HOME/source/current` → packages/
 *  - profile install under source:    `$DSH_HOME/source/current` → profiles/node_modules
 *  - npm install (lib production):    `$DSH_HOME/profiles/node_modules` closure
 *
 * The persistence class was renamed across snapshots (`SessionPersistenceJsonl`
 * in older builds, `JsonlSessionPersistence` in rc.1). We accept both so the
 * diagnostic scripts work against whatever snapshot is currently linked.
 */
import { readlinkSync, readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { homedir } from 'node:os'
import { createRequire } from 'node:module'

export const DSH_HOME = process.env.DSH_HOME ?? join(homedir(), '.dsh')

/** Locate the checkout: follow ~/.dsh/source/current, else newest staging-*. */
export function resolveSourceRoot() {
  const current = join(DSH_HOME, 'source', 'current')
  try {
    return readlinkSync(current)
  } catch {
    const sourceDir = join(DSH_HOME, 'source')
    const candidates = readdirSync(sourceDir).filter(n => n.startsWith('staging-'))
    if (candidates.length === 0) {
      throw new Error(`cannot locate DSH source root: ${sourceDir} has no staging-* and current is missing`)
    }
    return join(sourceDir, candidates.sort().pop())
  }
}

export const defaultSessionsRoot = () => join(DSH_HOME, 'sessions')

/** Absolute path to the package dir for an npm-scope package, or null. */
function packageDir(baseNodeModules, pkgName) {
  return join(baseNodeModules, ...pkgName.split('/'))
}

/**
 * Resolve the require handle + mode for an `@deepseek-ai/*` package.
 * Tries, in order: source packages/, source profile closure, npm profile closure.
 */
function resolvePkgRequire(pkgName, sourceRelPath) {
  const current = join(DSH_HOME, 'source', 'current')
  if (existsSync(current)) {
    // 1) genuine source checkout: <current>/packages/<...>
    const srcPkg = join(current, 'packages', ...sourceRelPath)
    if (existsSync(join(srcPkg, 'package.json'))) {
      return { require: createRequire(join(srcPkg, 'package.json')), mode: 'source' }
    }
    // 2) profile install under source (slot-a/slot-b): <current>/profiles/node_modules
    const profBase = join(current, 'profiles', 'node_modules')
    const profPkg = packageDir(profBase, pkgName)
    if (existsSync(join(profPkg, 'package.json'))) {
      return { require: createRequire(join(profPkg, 'package.json')), mode: 'profile' }
    }
  }
  // 3) npm install (lib production): <DSH_HOME>/profiles/node_modules
  const npmBase = join(DSH_HOME, 'profiles', 'node_modules')
  const npmPkg = packageDir(npmBase, pkgName)
  return { require: createRequire(join(npmPkg, 'package.json')), mode: 'npm' }
}

/** Resolve the persistence backend require handle. */
function persistenceRequire() {
  return resolvePkgRequire('@deepseek-ai/dsh-session-persistence-jsonl', ['session', 'session-persistence-jsonl'])
}

/** Public handle to the persistence backend's require (for frame-level tools). */
export function persistenceRequireHandle() {
  return persistenceRequire()
}

/** Resolve the `@deepseek-ai/dsh-session` require handle (decodeStorageRecord). */
export function sessionRequire() {
  return resolvePkgRequire('@deepseek-ai/dsh-session', ['session', 'dsh-session']).require
}

/**
 * Build a persistence instance bound to the real session root.
 * Uses the COMPILED packages (lib/) so behaviour matches the running server.
 * Returns the resolved mode so callers can report which backend they used.
 */
export function loadPersistence(root = defaultSessionsRoot()) {
  const { require, mode } = persistenceRequire()
  // cordis: pre-0811 snapshots vendored it as `cordis`; the 20260811 snapshot
  // renamed it to `@deepseek-ai/cordis`. Try both so the diagnostic scripts
  // work against either layout.
  let Context
  try {
    ({ Context } = require('cordis'))
  } catch {
    ({ Context } = require('@deepseek-ai/cordis'))
  }
  const mod = require('@deepseek-ai/dsh-session-persistence-jsonl')
  // Class renamed across snapshots: older builds used SessionPersistenceJsonl.
  const Persistence = mod.JsonlSessionPersistence ?? mod.SessionPersistenceJsonl ?? mod.default
  const ctx = new Context()
  ctx.sessions = { list: () => [] } // no live sessions in a diagnostic context
  const persistence = new Persistence(ctx, { root, compression: 'zstd' })
  return { persistence, root, mode, sourceRoot: mode === 'source' ? resolveSourceRoot() : undefined }
}

/** Enumerate every session log under the root (project dir -> session dir). */
export async function enumerateSessionLogs(root = defaultSessionsRoot()) {
  const { readdir } = await import('node:fs/promises')
  const logs = []
  // 首次运行/空安装可能没有 sessions 根目录：视为无会话，而非崩溃
  let projects
  try {
    projects = await readdir(root, { withFileTypes: true })
  } catch {
    return logs
  }
  for (const project of projects
    .filter(e => e.isDirectory()).map(e => join(root, e.name))) {
    for (const dir of (await readdir(project, { withFileTypes: true }))
      .filter(e => e.isDirectory()).map(e => join(project, e.name))) {
      const log = join(dir, 'session.jsonl.zstd')
      const plain = join(dir, 'session.jsonl')
      const exists = await import('node:fs/promises').then(fs => Promise.all([
        fs.access(log).then(() => true, () => false),
        fs.access(plain).then(() => true, () => false),
      ]))
      if (exists[0]) logs.push({ id: dir.split('/').pop(), project, dir, log, compression: 'zstd' })
      else if (exists[1]) logs.push({ id: dir.split('/').pop(), project, dir, log: plain, compression: 'none' })
    }
  }
  return logs
}
