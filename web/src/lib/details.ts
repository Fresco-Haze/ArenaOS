import { Game } from '../model'
import type { Tournament } from '../model'

export const PRIZE_MAX = 1000000000
export const DESCRIPTION_MAX = 500

// What the form holds: strings only. `start` and `deadline` are datetime-local values in the device's time zone.
export type DetailsValues = { game: string; start: string; deadline: string; prize: string; description: string }
export type DetailsPayload = {
  game: Game | null
  startTime: string | null
  registrationDeadline: string | null
  prize: number | null
  description: string | null
}

export const emptyDetails: DetailsValues = { game: '', start: '', deadline: '', prize: '', description: '' }

const pad = (n: number) => ('0' + n).slice(-2)

// '' -> null (no prize); '50,000' -> 50000; 0 -> null; anything else -> undefined (invalid).
export function parsePrize(raw: string): number | null | undefined {
  const s = raw.replace(/[\s,]/g, '')
  if (s === '') return null
  if (!/^\d+$/.test(s)) return undefined
  const n = Number(s)
  if (n > PRIZE_MAX) return undefined
  return n === 0 ? null : n
}

export function prizeError(raw: string): string | null {
  return parsePrize(raw) === undefined ? 'Enter a whole number of KSh, up to 1,000,000,000.' : null
}

// Only checked when both the start and the deadline are filled in.
export function deadlineError(v: DetailsValues): string | null {
  if (!v.start || !v.deadline) return null
  const s = new Date(v.start).getTime()
  const d = new Date(v.deadline).getTime()
  return d > s ? 'The registration deadline must not be after the start.' : null
}

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
  return {
    game: t.game ?? '',
    start: isoToLocalInput(t.startTime),
    deadline: isoToLocalInput(t.registrationDeadline),
    prize: t.prize != null ? String(t.prize) : '',
    description: t.description ?? '',
  }
}

// If a date field still shows what the server has, send the server's exact value back
// (the picker has minute precision, the server may hold seconds).
export function toPayload(v: DetailsValues, original?: Tournament): DetailsPayload {
  const game = Game.safeParse(v.game)
  let startTime = localInputToIso(v.start)
  if (original?.startTime && v.start === isoToLocalInput(original.startTime)) startTime = original.startTime
  let registrationDeadline = localInputToIso(v.deadline)
  if (original?.registrationDeadline && v.deadline === isoToLocalInput(original.registrationDeadline)) {
    registrationDeadline = original.registrationDeadline
  }
  const description = v.description.trim()
  return {
    game: game.success ? game.data : null,
    startTime,
    registrationDeadline,
    prize: parsePrize(v.prize) ?? null,
    description: description === '' ? null : description,
  }
}

export function detailsChanged(v: DetailsValues, t: Tournament): boolean {
  const p = toPayload(v, t)
  return (
    p.game !== (t.game ?? null) ||
    p.startTime !== (t.startTime ?? null) ||
    p.registrationDeadline !== (t.registrationDeadline ?? null) ||
    p.prize !== (t.prize ?? null) ||
    p.description !== (t.description ?? null)
  )
}