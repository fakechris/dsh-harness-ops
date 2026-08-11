/**
 * dsh-restart-recover tests — interrupted-turn detection, continuation
 * injection, and the "never touch a normal session" guarantee.
 * @module tests/restart-recover.spec
 */

import { describe, expect, it, vi } from 'vitest'
import { lastTurnInterrupted, CONTINUE_MESSAGE, apply } from '../src/index.ts'
import type { SessionEvent } from '@deepseek-ai/dsh-session'

function ev<T extends SessionEvent['type']>(
  type: T,
  seq: number,
  data: Extract<SessionEvent, { type: T }>['data'],
  time = 1000 + seq,
): Extract<SessionEvent, { type: T }> {
  return { type, seq, time, data } as Extract<SessionEvent, { type: T }>
}

describe('lastTurnInterrupted', () => {
  it('detects a crash-repaired interrupted last turn', () => {
    const events = [
      ev('turn/start', 0, { turn: 1 }),
      ev('user/message', 1, { id: 'm', role: 'user', content: [{ type: 'text', text: 'x' }], source: { kind: 'user' } }),
      ev('turn/end', 2, { turn: 1, reason: { kind: 'interrupted' } }),
    ]
    expect(lastTurnInterrupted(events)).toBe(true)
  })

  it('returns false for a completed last turn', () => {
    const events = [
      ev('turn/start', 0, { turn: 1 }),
      ev('turn/end', 1, { turn: 1, reason: { kind: 'completed' } }),
    ]
    expect(lastTurnInterrupted(events)).toBe(false)
  })

  it('treats an open turn (torn log, no turn/end) as interrupted', () => {
    const events = [
      ev('turn/start', 0, { turn: 1 }),
      ev('user/message', 1, { id: 'm', role: 'user', content: [{ type: 'text', text: 'x' }], source: { kind: 'user' } }),
    ]
    expect(lastTurnInterrupted(events)).toBe(true)
  })

  it('returns false for empty or pre-turn logs', () => {
    expect(lastTurnInterrupted([])).toBe(false)
    expect(lastTurnInterrupted([ev('user/message', 0, { id: 'm', role: 'user', content: [{ type: 'text', text: 'x' }], source: { kind: 'user' } })])).toBe(false)
  })

  it('only checks the LAST turn (earlier interrupted turns do not count)', () => {
    const events = [
      ev('turn/start', 0, { turn: 1 }),
      ev('turn/end', 1, { turn: 1, reason: { kind: 'interrupted' } }),
      ev('turn/start', 2, { turn: 2 }),
      ev('turn/end', 3, { turn: 2, reason: { kind: 'completed' } }),
    ]
    expect(lastTurnInterrupted(events)).toBe(false)
  })
})

describe('continuation message', () => {
  it('asks the agent to continue and verify unknown tool outcomes', () => {
    expect(CONTINUE_MESSAGE).toContain('继续')
    expect(CONTINUE_MESSAGE).toContain('结果未知')
    expect(CONTINUE_MESSAGE).toContain('只读或幂等')
  })
})

describe('apply listener wiring', () => {
  it('injects followup only for interrupted sessions, never normal ones', () => {
    let captured: ((payload: { agent: unknown }) => void) | undefined
    const fakeCtx = {
      on: (_name: string, listener: (payload: { agent: unknown }) => void) => {
        captured = listener
        return () => undefined
      },
    }
    apply(fakeCtx as never)
    expect(captured).toBeDefined()

    // Normal session → no followup.
    const normal = {
      session: {
        events: [
          ev('turn/start', 0, { turn: 1 }),
          ev('turn/end', 1, { turn: 1, reason: { kind: 'completed' } }),
        ],
        header: { cwd: '/ws', createdAt: 1000 },
      },
      followup: vi.fn(),
    }
    captured!({ agent: normal as never })
    expect(normal.followup).not.toHaveBeenCalled()

    // Interrupted session → followup injected with the continuation message.
    const interrupted = {
      session: {
        events: [
          ev('turn/start', 0, { turn: 1 }),
          ev('user/message', 1, { id: 'm', role: 'user', content: [{ type: 'text', text: 'do X' }], source: { kind: 'user' } }),
          ev('tool/call', 2, { turn: 1, step: 1, callId: 'c1', name: 'bash', arguments: 'ls' }),
          ev('turn/end', 3, { turn: 1, reason: { kind: 'interrupted' } }),
        ],
        header: { cwd: '/ws', createdAt: 1000 },
      },
      followup: vi.fn(),
    }
    captured!({ agent: interrupted as never })
    expect(interrupted.followup).toHaveBeenCalledTimes(1)
    const msg = interrupted.followup.mock.calls[0]![0] as { content: Array<{ text: string }> }
    expect(msg.content[0]!.text).toContain('继续')
  })

  it('honors cwdFilter', () => {
    let captured: ((payload: { agent: unknown }) => void) | undefined
    const fakeCtx = {
      on: (_name: string, listener: (payload: { agent: unknown }) => void) => {
        captured = listener
        return () => undefined
      },
    }
    apply(fakeCtx as never, { cwdFilter: ['/allowed'] })

    const other = {
      session: {
        events: [
          ev('turn/start', 0, { turn: 1 }),
          ev('turn/end', 1, { turn: 1, reason: { kind: 'interrupted' } }),
        ],
        header: { cwd: '/other', createdAt: 1000 },
      },
      followup: vi.fn(),
    }
    captured!({ agent: other as never })
    expect(other.followup).not.toHaveBeenCalled()
  })

  it('disabled config registers no listener', () => {
    const fakeCtx = { on: vi.fn() }
    apply(fakeCtx as never, { enabled: false })
    expect(fakeCtx.on).not.toHaveBeenCalled()
  })
})
