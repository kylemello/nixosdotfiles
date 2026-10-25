import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { Spend } from '../types'

type Ledger = { seen: number; days: Record<string, number> }

const spend = atom({ plugin: 'session-cost', key: 'spend' } as const, null)

// The last total this process counted, so a /clear (new session id) isn't counted twice.
let last: number | undefined

const money = (usd: number) => `$${usd.toFixed(2)}`

const dayOf = (ms: number) => {
  const d = new Date(ms)
  const pad = (n: number) => String(n).padStart(2, '0')

  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

const weekStart = (ms: number) => {
  const d = new Date(ms)
  d.setHours(0, 0, 0, 0)
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7))

  return d.getTime()
}

const parse = (text: string): Ledger | undefined => {
  try {
    return JSON.parse(text) as Ledger
  } catch {
    return undefined
  }
}

async function folder($: EngineInterface) {
  return `${await $.env.get('HOME')}/.claude/session-cost`
}

async function record($: EngineInterface, usd: number) {
  const path = `${await folder($)}/${await $.session.id()}.json`
  const held = (await $.fs.exists(path)) ? parse(await $.fs.read(path)) : undefined
  const base = held?.seen ?? last ?? 0
  const today = dayOf(await $.clock.now())
  const days = { ...held?.days }
  days[today] = (days[today] ?? 0) + (usd >= base ? usd - base : usd)
  last = usd
  await $.fs.write(path, JSON.stringify({ seen: usd, days }))
}

async function total($: EngineInterface, usd: number): Promise<Spend> {
  const dir = await folder($)
  const now = await $.clock.now()
  const today = dayOf(now)
  const since = weekStart(now)
  const monday = dayOf(since)
  let day = 0
  let week = 0

  const entries = (await $.fs.exists(dir)) ? await $.fs.list(dir) : []
  for (const entry of entries) {
    if (entry.kind !== 'file' || !entry.name.endsWith('.json') || entry.mtimeMs < since) {
      continue
    }
    const ledger = parse(await $.fs.read(`${dir}/${entry.name}`))
    for (const [date, spent] of Object.entries(ledger?.days ?? {})) {
      if (date === today) day += spent
      if (date >= monday) week += spent
    }
  }

  return { session: usd, today: day, week }
}

async function refresh($: EngineInterface, usd: number | undefined) {
  if (usd !== undefined && usd > 0) {
    await record($, usd)
  }
  const value = usd === undefined ? null : await total($, usd)
  await update($, spend, () => value)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await refresh($, (await $.session.usage()).cost?.usd)

    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    if (e.changed.includes('cost')) {
      await refresh($, e.cost?.usd)
    }

    return next(e)
  })

  on('ui.render', { component: 'SessionMode', surface: 'desktop' }, async ($, e, next) => {
    const value = await read($, spend)
    if (value === null) {
      return next(e)
    }
    const line = `${money(value.session)} · today ${money(value.today)} · week ${money(value.week)}`

    return next({ ...e, props: { ...e.props, modes: [...e.props.modes, line] } })
  })
}
