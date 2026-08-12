/**
 * Standalone vitest config for dsh-restart-recover: alias DSH peer packages
 * to the running checkout (same strategy as dsh-track). DSH_SOURCE selects
 * the slot (default live install ~/.dsh/source/current).
 */
import { defineConfig } from 'vitest/config'
import { fileURLToPath } from 'node:url'

const DSH = process.env.DSH_SOURCE ?? '/Users/chris/.dsh/source/current'

export default defineConfig({
  resolve: {
    alias: [
      { find: '@deepseek-ai/cordis', replacement: fileURLToPath(new URL(`${DSH}/vendor/cordis/lib/index.js`, import.meta.url)) },
      { find: '@deepseek-ai/dsh-agent', replacement: fileURLToPath(new URL(`${DSH}/packages/core/agent/lib/index.js`, import.meta.url)) },
      { find: '@deepseek-ai/dsh-session', replacement: fileURLToPath(new URL(`${DSH}/packages/core/session/lib/index.js`, import.meta.url)) },
    ],
  },
})
