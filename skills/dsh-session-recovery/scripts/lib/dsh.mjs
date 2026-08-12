/**
 * Shared helpers: resolve the DSH session persistence backend and load it
 * exactly as the running `dsh web` server uses it, across both install modes:
 *
 *  - source checkout (A/B snapshots): `$DSH_HOME/source/current` → packages/
 *  - npm install (lib production):  `$DSH_HOME/profiles/node_modules` closure
 */
import { readlinkSync, readdirSync } from 'node:fs'
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

/** 源码 checkout 是否存在（A/B 快照机制的特征）。 */
function hasSourceCheckout() {
  try {
    const current = join(DSH_HOME, 'source', 'current')
    readlinkSync(current)
    return true
  } catch {
    return false
  }
}

/**
 * 双路径解析 persistence 后端。判别以「是否有源码 checkout」为准：
 * 源码模式（A/B 快照）→ 源码 packages/；npm 安装（lib 生产）→ profile 闭包。
 */
function persistenceRequire() {
  if (hasSourceCheckout()) {
    const sourceRoot = resolveSourceRoot()
    const pkgDir = join(sourceRoot, 'packages', 'session', 'session-persistence-jsonl')
    return { require: createRequire(join(pkgDir, 'package.json')), mode: 'source' }
  }
  const pkgDir = join(DSH_HOME, 'profiles', 'node_modules', '@deepseek-ai', 'dsh-session-persistence-jsonl')
  return { require: createRequire(join(pkgDir, 'package.json')), mode: 'npm' }
}

/** Public handle to the persistence backend's require (for frame-level tools). */
export function persistenceRequireHandle() {
  return persistenceRequire()
}

/**
 * 双路径解析 `@deepseek-ai/dsh-session` 的 require（repair 脚本 decodeStorageRecord 用）。
 * 判别与 persistenceRequire 一致：源码 checkout → 源码 packages/；npm → profile 闭包。
 */
export function sessionRequire() {
  if (hasSourceCheckout()) {
    const sourceRoot = resolveSourceRoot()
    const pkgDir = join(sourceRoot, 'packages', 'session', 'session-persistence-jsonl')
    return createRequire(join(pkgDir, 'package.json'))
  }
  const pkgDir = join(DSH_HOME, 'profiles', 'node_modules', '@deepseek-ai', 'dsh-session')
  return createRequire(join(pkgDir, 'package.json'))
}

/**
 * Build a SessionPersistenceJsonl instance bound to the real session root.
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
  const { SessionPersistenceJsonl } = require('@deepseek-ai/dsh-session-persistence-jsonl')
  const ctx = new Context()
  ctx.sessions = { list: () => [] } // no live sessions in a diagnostic context
  const persistence = new SessionPersistenceJsonl(ctx, { root, compression: 'zstd' })
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
