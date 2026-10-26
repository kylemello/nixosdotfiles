import { expect, mock, test } from 'claude-code/testing'

const DIR = '/home/test/.claude/session-cost'
const SUNDAY_NOON = new Date(2026, 9, 25, 12).getTime()
const LAST_WEEK = new Date(2026, 9, 17, 12).getTime()

test('the status line shows this session, today and the week across sessions', async ($, on) => {
  const clock = mock.clock(on, { now: SUNDAY_NOON })
  mock.env(on, { HOME: '/home/test' })

  const files = new Map<string, { text: string; mtimeMs: number }>([
    [`${DIR}/other.json`, {
      text: JSON.stringify({ seen: 5, days: { '2026-10-20': 3, '2026-10-25': 2 } }),
      mtimeMs: SUNDAY_NOON,
    }],
    [`${DIR}/stale.json`, {
      text: JSON.stringify({ seen: 40, days: { '2026-10-17': 40 } }),
      mtimeMs: LAST_WEEK,
    }],
  ])
  on('fs.exists', (_, e) => ({ value: e.path === DIR || files.has(e.path) }))
  on('fs.read', (_, e) => ({ value: files.get(e.path)?.text ?? '' }))
  on('fs.write', (_, e) => {
    files.set(e.path, { text: e.text, mtimeMs: clock.now() })

    return { value: undefined }
  })
  on('fs.list', () => ({
    value: [...files].map(([path, file]) => ({
      name: path.slice(DIR.length + 1),
      kind: 'file' as const,
      size: file.text.length,
      mtimeMs: file.mtimeMs,
      isLink: false,
    })),
  }))

  on('session.id', () => ({ value: 'mine' }))
  on('session.usage', () => ({
    value: { startedAt: 0, context: { window: 200000 }, rateLimits: [], cost: { usd: 1.5 } },
  }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.measure', (_, e) => ({ changed: e.changed }))

  const status: (string | undefined)[] = []
  on('ui.status', (_, e) => {
    status.push(e.text)

    return { value: undefined }
  })

  const measure = (usd: number) =>
    $.session.measure({
      context: { window: 200000 },
      rateLimits: [],
      cost: { usd },
      changed: ['cost'],
    })

  // The desktop app starts its session over the SDK, before any surface attaches.
  await $.session.start({ cwd: '/', surface: null, isInteractive: false })
  expect(status.at(-1)).toBe('$1.50 · today $3.50 · week $6.50')

  await measure(2.25)
  expect(status.at(-1)).toBe('$2.25 · today $4.25 · week $7.25')

  await clock.set(new Date(2026, 9, 26, 9).getTime())
  await measure(3)
  expect(status.at(-1)).toBe('$3.00 · today $0.75 · week $0.75')
})

test('a terminal session counts its spend but pins no line', async ($, on) => {
  mock.clock(on, { now: SUNDAY_NOON })
  mock.env(on, { HOME: '/home/test' })

  const written: string[] = []
  on('fs.exists', () => ({ value: false }))
  on('fs.write', (_, e) => {
    written.push(e.path)

    return { value: undefined }
  })
  on('fs.list', () => ({ value: [] }))

  on('session.id', () => ({ value: 'mine' }))
  on('session.usage', () => ({
    value: { startedAt: 0, context: { window: 200000 }, rateLimits: [], cost: { usd: 1.5 } },
  }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))

  const status: (string | undefined)[] = []
  on('ui.status', (_, e) => {
    status.push(e.text)

    return { value: undefined }
  })

  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  expect(written).toEqual([`${DIR}/mine.json`])
  expect(status).toEqual([])
})
