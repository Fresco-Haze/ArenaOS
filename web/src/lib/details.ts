import { Game } from '../model'
import type { Tournament } from '../model'

export const PRIZE_MAX = 100

// What the form holds: strings only. `start` is a datetime-local value in the device's time zone.
export type DetailsValues = { game: string; start: string; prize: string }
export type DetailsPayload = { game: Game | null; startTime: string | null; prize: string | null }

export const emptyDetails: DetailsValues = { game: '', start: '', prize: '' }

const pad = (n: number) => ('0' + n).slice(-2)

// "2026-11-08T19:00" (device time zone) -> "2026-11-08T16:00:00Z" (UTC, whole seconds)
export function localInputToIso(value: string): string | null {
  if (!value) return null
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return null
  return d.toISOString().replace(/\.\d{3}Z$/, 'Z')
}

export function isoToLocalInput(value: string | null | undefined): string {
  if (!value) return ''
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return ''
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

export function detailsFromTournament(t: Tournament): DetailsValues {
  return { game: t.game ?? '', start: isoToLocalInput(t.startTime), prize: t.prize ?? '' }
}

// If the start field still shows what the server has, send the server's exact value back
// (the picker has minute precision, the server may hold seconds).
export function toPayload(v: DetailsValues, original?: Tournament): DetailsPayload {
  const game = Game.safeParse(v.game)
  const prize = v.prize.trim()
  let startTime = localInputToIso(v.start)
  if (original?.startTime && v.start === isoToLocalInput(original.startTime)) startTime = original.startTime
  return {
    game: game.success ? game.data : null,
    startTime,
    prize: prize === '' ? null : prize,
  }
}

export function detailsChanged(v: DetailsValues, t: Tournament): boolean {
  const p = toPayload(v, t)
  return p.game !== (t.game ?? null) || p.startTime !== (t.startTime ?? null) || p.prize !== (t.prize ?? null)
}