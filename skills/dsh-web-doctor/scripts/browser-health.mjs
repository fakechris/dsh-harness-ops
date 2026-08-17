#!/usr/bin/env node
/**
 * browser-health.mjs — REAL browser acceptance probe for the dsh web app.
 *
 * HTTP 200 proves only that something answers; the dsh-track incident (HTML
 * 200, plugin fails to load, client.js throws "process is not defined") shows
 * the page can be broken while the socket is healthy. This probe opens the
 * page in a fresh headless Chromium profile, listens for page-level and
 * console errors, checks the "Failed to load plugins" marker, and verifies the
 * app actually rendered.
 *
 * Zero-dependency by design (the doctor must work out-of-band): it drives the
 * system Chrome/Chromium with --headless --dump-dom, and captures the page's
 * console via Chrome's own --enable-logging=stderr (console.error/uncaught
 * exceptions surface as [ERROR:CONSOLE(...)] lines).
 *
 * Usage:
 *   node browser-health.mjs [--url http://127.0.0.1:3080/]
 * stdout: one JSON line { status: "PASS"|"FAIL"|"UNKNOWN", summary, evidence[], failedPlugins[] }
 * Exit 0 = probe COMPLETED (status says PASS or FAIL); exit 2 = probe could
 * NOT run (no browser / page unreachable / crashed) → the caller must report
 * UNKNOWN, never PASS.
 */
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, existsSync, statSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { parseArgs } from 'node:util'

const { values } = parseArgs({ options: { url: { type: 'string', default: 'http://127.0.0.1:3080/' } } })
const URL = values.url

const CHROME_CANDIDATES = [
  process.env.DSH_CHROME_BIN,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
  '/usr/bin/google-chrome',
  '/usr/bin/google-chrome-stable',
  '/usr/bin/chromium',
  '/usr/bin/chromium-browser',
  '/usr/bin/chrome-headless-shell',
  '/opt/homebrew/bin/chromium',
  '/opt/homebrew/bin/google-chrome',
  '/opt/homebrew/bin/chrome-headless-shell',
].filter(Boolean)

function findChrome() {
  for (const candidate of CHROME_CANDIDATES) {
    if (existsSync(candidate)) return candidate
  }
  return undefined
}

function json(status, summary, evidence, failedPlugins = []) {
  process.stdout.write(JSON.stringify({ status, summary, evidence, failedPlugins }) + '\n')
}

const chrome = findChrome()
if (chrome === undefined) {
  json('UNKNOWN', 'no Chrome/Chromium binary found; set DSH_CHROME_BIN', [
    'browser probe cannot run without a Chromium-family binary',
  ])
  process.exit(2)
}

const profile = mkdtempSync(join(tmpdir(), 'dsh-doctor-browser-'))
const args = [
  '--headless=new',
  '--disable-gpu',
  '--no-sandbox',
  '--disable-dev-shm-usage',
  '--user-data-dir=' + profile,
  '--enable-logging=stderr',
  '--v=0',
  '--virtual-time-budget=15000',
  '--timeout=25000',
  '--dump-dom',
  URL,
]

let probe
try {
  probe = spawnSync(chrome, args, { encoding: 'utf8', timeout: 60000, maxBuffer: 64 * 1024 * 1024 })
} catch (error) {
  rmSync(profile, { recursive: true, force: true })
  json('UNKNOWN', `chrome launch failed: ${error.message}`, [String(error)])
  process.exit(2)
}

const dom = probe.stdout ?? ''
const consoleLog = probe.stderr ?? ''

// Console frame lines look like:
//   [1234:5678:000000/000000.000000:ERROR:CONSOLE(12)] "message", source: http://... (12)
const consoleLines = consoleLog.split('\n').filter(line => line.includes('CONSOLE'))
const errorConsole = consoleLines.filter(line => /ERROR:CONSOLE|WARNING:CONSOLE.*error/i.test(line))
const pageErrors = consoleLines.filter(line =>
  /Uncaught |process is not defined|Cannot read propert|TypeError:|ReferenceError:|SyntaxError:|is not defined/i.test(line),
)
const pluginLoadFailures = consoleLines.filter(line => /Failed to load plugin/i.test(line))

function extractPluginNames(lines) {
  const names = []
  for (const line of lines) {
    const match = line.match(/Failed to load plugin[s]?\s*:?\s*([^\"]+)/i)
    if (match) names.push(match[1].trim())
  }
  return names
}

const failedPlugins = extractPluginNames(pluginLoadFailures)

// A rendered app produces a non-trivial DOM; a dead page stays near-empty.
const rendered = dom.length > 400 && /\<body[\s\>]/.test(dom)

if (!rendered && probe.status !== 0) {
  rmSync(profile, { recursive: true, force: true })
  json('UNKNOWN', 'chrome did not render the page', [
    `exit=${probe.status ?? 'signal'}`,
    ...consoleLines.slice(0, 5),
  ])
  process.exit(2)
}

const evidence = []
if (pageErrors.length > 0) evidence.push(...pageErrors.slice(0, 10))
if (pluginLoadFailures.length > 0) evidence.push(...pluginLoadFailures.slice(0, 10))
if (errorConsole.length > 0) evidence.push(...errorConsole.slice(0, 10))
if (!rendered) evidence.push('page produced no meaningful DOM')

const failed = pageErrors.length > 0 || pluginLoadFailures.length > 0 || !rendered
const summary = failed
  ? `browser probe FAILED: ${failedPlugins.length > 0 ? 'plugins failed to load' : 'page errors or no render'}`
  : 'browser probe PASS: page rendered, no page/console errors, plugins loaded'

rmSync(profile, { recursive: true, force: true })
json(failed ? 'FAIL' : 'PASS', summary, evidence.slice(0, 20), failedPlugins)
process.exit(0)
