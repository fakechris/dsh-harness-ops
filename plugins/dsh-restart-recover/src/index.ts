/**
 * dsh-restart-recover — auto-continue interrupted agent turns after a restart.
 *
 * The agent runs INSIDE the dsh web process; a restart kills the in-memory
 * turn. dsh's crash repair (repair.ts) closes the torn log with a synthetic
 * `turn/end { reason: interrupted }` and a `TOOL_OUTCOME_UNKNOWN` tool result,
 * and `ctx.agents.resume` re-opens the session with that context. But the
 * resumed agent sits idle waiting for input — the user must type "continue".
 *
 * This plugin closes that gap: it listens for `agent/created` (fires for both
 * create and resume), detects that the session's last turn was interrupted,
 * and injects a follow-up user message so the agent continues on its own,
 * carrying the TOOL_OUTCOME_UNKNOWN context (the model decides whether to
 * retry per the "retry only if read-only or idempotent" discipline).
 *
 * Host-side only, driven by the authoritative `agent/created` signal — no
 * browser timing races (the frontend `connection/reset` event is too early
 * and cannot see the host agent lifecycle).
 *
 * Pairs with the dsh-web-guard skill: the guard auto-relaunches the web
 * process (launchd/systemd), this plugin continues the interrupted turn.
 * @module @deepseek-ai/dsh-restart-recover
 */

import type { Context } from 'cordis'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type { SessionEvent } from '@deepseek-ai/dsh-session'

export const name = '@deepseek-ai/dsh-restart-recover'

/** Plugin configuration. */
export interface Config {
  /** Enable auto-continuation of interrupted sessions (default true). */
  enabled?: boolean
  /** Only auto-continue sessions whose cwd is in this list (default: all). */
  cwdFilter?: string[]
  /** Skip auto-continue for sessions whose last turn ended less than this many ms ago (default 0 = always). */
  minInterruptAgeMs?: number
}

/** Whether a session log's last turn ended in `interrupted` (crash-repaired). */
export function lastTurnInterrupted(events: readonly SessionEvent[]): boolean {
  // Scan from the end: the last turn/end (or the synthetic closer) tells us.
  for (let i = events.length - 1; i >= 0; i--) {
    const e = events[i]
    if (e === undefined) continue
    if (e.type === 'turn/end') {
      const reason = (e.data as { reason?: { kind?: string } } | undefined)?.reason
      return reason?.kind === 'interrupted'
    }
    // A torn log may end without a turn/end (repair closes it on load); treat
    // an open turn as interrupted too.
    if (e.type === 'turn/start') return true
  }
  return false
}

/** The continuation message injected into a resumed interrupted session. */
export const CONTINUE_MESSAGE = '检测到上次会话因重启被中断，请继续之前的工作。若存在结果未知的工具调用，请先核查其实际影响再决定是否重试（只对只读或幂等操作直接重试）。'

export function apply(ctx: Context, config?: Config): void {
  const enabled = config?.enabled ?? true
  if (!enabled) return

  const cwdFilter = config?.cwdFilter
  const minAge = config?.minInterruptAgeMs ?? 0

  const listener = (payload: { agent: Agent }): void => {
    const agent = payload.agent
    try {
      const events = agent.session.events
      if (!lastTurnInterrupted(events)) return // normal session, never touch

      // cwd filter: only auto-continue sessions in the allowed workspaces.
      const cwd = agent.session.header.cwd
      if (cwdFilter !== undefined && cwd !== undefined && !cwdFilter.includes(cwd)) return

      // Age filter: skip freshly-crashed sessions (e.g. an explicit cancel
      // that also lands as interrupted) unless old enough.
      const lastEnd = events.findLast((e) => e.type === 'turn/end') as
        | { time?: number; data?: { reason?: { kind?: string } } }
        | undefined
      const lastTime = lastEnd?.time ?? agent.session.header.createdAt ?? 0
      if (minAge > 0 && Date.now() - lastTime < minAge) return

      // Inject a continuation as the next turn. source: plugin keeps it
      // distinguishable from a real user message while still driving the loop.
      const msg = {
        id: `resume-${Math.random().toString(36).slice(2, 10)}`,
        role: 'user' as const,
        content: [{ type: 'text' as const, text: CONTINUE_MESSAGE }],
        source: { kind: 'plugin' as const, plugin: '@deepseek-ai/dsh-restart-recover' },
      }
      agent.followup(msg as never)
      // The follow-up is durable in the session log via the agent loop.
    } catch (error) {
      console.error('[dsh-restart-recover] auto-continue failed:', error)
    }
  }

  // cordis dispatch: [carrier, 'agent/created', { agent }]; carrier is `this`.
  // ctx.on registers on the plugin fiber and auto-disposes with it.
  ctx.on('agent/created', listener as (this: never, payload: { agent: Agent }) => void)
}
