import type { BracketNode, BracketView } from '../model'
import { groupByRound, roundName, splitThirdPlace } from './bracket'

// A node with a bye slot never produces a match.
const isBye = (n: BracketNode) => n.slotA.type === 'Bye' || n.slotB.type === 'Bye'

// total is null for double elimination: the reset match may never be needed,
// so a fixed denominator would be wrong.
export function matchStats(bracket: BracketView): { played: number; total: number | null } {
  const real = bracket.nodes.filter((n) => !isBye(n))
  const played = real.filter((n) => n.match?.status === 'Completed').length
  const total = bracket.format === 'DoubleElimination' ? null : real.length
  return { played, total }
}

// Single elimination only: the first round that still has an unfinished match.
export function currentRoundName(bracket: BracketView): string | null {
  if (bracket.format !== 'SingleElimination') return null
  const groups = groupByRound(splitThirdPlace(bracket).main)
  const open = groups.find((g) =>
    g.nodes.some((n) => !isBye(n) && n.match?.status !== 'Completed'),
  )
  return open ? roundName(open.round, groups.length) : null
}