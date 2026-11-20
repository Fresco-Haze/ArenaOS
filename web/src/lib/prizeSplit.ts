import { z } from 'zod'
import { apiVoid } from '../api'

export const PrizeSplitView = z.object({
  prize: z.number().nullable(),
  places: z.array(z.object({ place: z.number(), percent: z.number(), amount: z.number().nullable() })),
})

export const MAX_PLACES = 8

// "1st", "2nd", "3rd", "4th" ... "11th"
export function ordinal(n: number): string {
  const v = n % 100
  if (v >= 11 && v <= 13) return `${n}th`
  const last = n % 10
  return `${n}${last === 1 ? 'st' : last === 2 ? 'nd' : last === 3 ? 'rd' : 'th'}`
}

// The same rule as the server: whole shillings rounded down, leftovers to first place,
// so the amounts always add up to the prize. Computed here so a prize edit shows at once.
export function splitAmounts(prize: number, percents: number[]): number[] {
  if (percents.length === 0) return []
  const parts = percents.map((p) => Math.floor((prize * p) / 100))
  const left = prize - parts.reduce((a, b) => a + b, 0)
  return [parts[0] + left, ...parts.slice(1)]
}

// Mirrors the server's checks, in the same order, so the form can explain a problem before saving.
export function validatePercents(ps: number[]): string | null {
  if (ps.length === 0) return 'Add at least one place'
  if (ps.length > MAX_PLACES) return `A split can have at most ${MAX_PLACES} places`
  if (ps.some((p) => !Number.isInteger(p) || p < 1)) return 'Every place needs a whole number of at least 1%'
  if (ps.some((p, i) => i > 0 && p > ps[i - 1])) return 'A lower place cannot get more than the place above it'
  if (ps.reduce((a, b) => a + b, 0) !== 100) return 'The percentages must add up to 100'
  return null
}

// Owner only, and only until the tournament starts.
export function savePrizeSplit(tournamentId: number, percents: number[]) {
  return apiVoid(`/tournaments/${tournamentId}/prize-split`, {
    method: 'PUT',
    body: JSON.stringify({ percents }),
  })
}

export function clearPrizeSplit(tournamentId: number) {
  return apiVoid(`/tournaments/${tournamentId}/prize-split`, { method: 'DELETE' })
}