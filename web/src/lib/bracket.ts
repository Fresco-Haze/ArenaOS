import type { BracketNode,BracketView, Slot } from '../model'
import { participantName } from './participants'

export type RoundGroup = { round: number; nodes: BracketNode[] }

export function groupByRound(nodes: BracketNode[]): RoundGroup[] {
  const byRound = new Map<number, BracketNode[]>()
  for (const n of nodes) {
    const list = byRound.get(n.round) ?? []
    list.push(n)
    byRound.set(n.round, list)
  }
  return [...byRound.entries()]
    .sort(([a], [b]) => a - b)
    .map(([round, ns]) => ({ round, nodes: [...ns].sort((a, b) => a.nodeId - b.nodeId) }))
}

export function roundName(roundNumber: number, totalRounds: number): string {
  const fromEnd = totalRounds - roundNumber
  if (fromEnd === 0) return 'Final'
  if (fromEnd === 1) return 'Semifinals'
  if (fromEnd === 2) return 'Quarterfinals'
  return `Round ${roundNumber}`
}

function singularRoundName(label: string, roundNumber: number): string {
  if (label === 'Semifinals') return 'Semifinal'
  if (label === 'Quarterfinals') return 'Quarterfinal'
  if (label === 'Final') return 'Final'
  return `Round ${roundNumber}`
}

// A short name for each node, used when another slot is still waiting on it:
// "Winner of Semifinal 1". Only numbered when its round has more than one match.
export function buildNodeLabels(groups: RoundGroup[], totalRounds: number): Map<number, string> {
  const labels = new Map<number, string>()
  for (const g of groups) {
    const base = singularRoundName(roundName(g.round, totalRounds), g.round)
    g.nodes.forEach((n, i) => {
      labels.set(n.nodeId, g.nodes.length === 1 ? base : `${base} ${i + 1}`)
    })
  }
  return labels
}

export function slotLabel(slot: Slot, nodeLabels: Map<number, string>): string {
  switch (slot.type) {
    case 'Filled':
      return participantName(slot.participant)
    case 'AwaitingWinnerOf':
      return `Winner of ${nodeLabels.get(slot.node) ?? 'an earlier match'}`
    case 'AwaitingLoserOf':
      return `Loser of ${nodeLabels.get(slot.node) ?? 'an earlier match'}`
    case 'Bye':
      return 'Bye'
  }
}

// The champion is derived, never decided: it just reads the final's own outcome.
export function champion(groups: RoundGroup[]): string | null {
  if (groups.length === 0) return null
  const final = groups[groups.length - 1]
  if (final.nodes.length !== 1) return null
  const node = final.nodes[0]
  const match = node.match
  if (!match || match.status !== 'Completed' || !match.outcome) return null
  if (!('winner' in match.outcome)) return null // Draw / NoContest carry no winner
  const winningSlot = match.outcome.winner === 'A' ? node.slotA : node.slotB
  return winningSlot.type === 'Filled' ? participantName(winningSlot.participant) : null
}



export function actionableMatches(nodes: BracketNode[]): BracketNode[] {
  return nodes.filter((n) => n.match && (n.match.status === 'Scheduled' || n.match.status === 'InProgress'))
}


// The bronze node shares the final's round, so it must be pulled out before
// grouping. Otherwise the final's round has two nodes and champion() gives up.
export function splitThirdPlace(bracket: BracketView): {
  main: BracketNode[]
  thirdPlace: BracketNode | null
} {
  const id = bracket.thirdPlaceNodeId
  if (id === null) return { main: bracket.nodes, thirdPlace: null }
  return {
    main: bracket.nodes.filter((n) => n.nodeId !== id),
    thirdPlace: bracket.nodes.find((n) => n.nodeId === id) ?? null,
  }
}

// Mirrors the backend rule: the final AND the third-place match (if one exists)
// must both be Completed.
export function isBracketDecided(bracket: BracketView): boolean {
  if (bracket.grandFinalNodeId != null) return isDoubleElimDecided(bracket)
  const { main, thirdPlace } = splitThirdPlace(bracket)
  const groups = groupByRound(main)
  if (groups.length === 0) return false
  const final = groups[groups.length - 1]
  const finalDone = final.nodes.length === 1 && final.nodes[0].match?.status === 'Completed'
  const thirdDone = thirdPlace === null || thirdPlace.match?.status === 'Completed'
  return finalDone && thirdDone
}
export function splitDoubleElim(bracket: BracketView): {
  winners: BracketNode[]
  losers: BracketNode[]
  grandFinal: BracketNode | null
  reset: BracketNode | null
} {
  const gfId = bracket.grandFinalNodeId ?? null
  const resetId = bracket.resetNodeId ?? null
  const grandFinal = bracket.nodes.find((n) => n.nodeId === gfId) ?? null
  const reset = bracket.nodes.find((n) => n.nodeId === resetId) ?? null
  const rest = bracket.nodes.filter((n) => n.nodeId !== gfId && n.nodeId !== resetId)
  return {
    winners: rest.filter((n) => n.stage === 'Winners'),
    losers: rest.filter((n) => n.stage === 'Losers'),
    grandFinal,
    reset,
  }
}

export function sectionRoundNames(count: number, prefix: 'Winners' | 'Losers'): string[] {
  return Array.from({ length: count }, (_, i) =>
    i === count - 1 ? `${prefix} final` : `${prefix} round ${i + 1}`,
  )
}

export function buildDoubleElimLabels(
  sections: { groups: RoundGroup[]; names: string[] }[],
  grandFinal: BracketNode | null,
  reset: BracketNode | null,
): Map<number, string> {
  const labels = new Map<number, string>()
  for (const s of sections) {
    s.groups.forEach((g, gi) => {
      g.nodes.forEach((n, i) => {
        labels.set(n.nodeId, g.nodes.length === 1 ? s.names[gi] : `${s.names[gi]} match ${i + 1}`)
      })
    })
  }
  if (grandFinal) labels.set(grandFinal.nodeId, 'Grand final')
  if (reset) labels.set(reset.nodeId, 'Reset match')
  return labels
}

function winnerName(node: BracketNode | null): string | null {
  const m = node?.match
  if (!node || !m || m.status !== 'Completed' || !m.outcome || !('winner' in m.outcome)) return null
  const slot = m.outcome.winner === 'A' ? node.slotA : node.slotB
  return slot.type === 'Filled' ? participantName(slot.participant) : null
}

// Mirrors CompleteTournament: the grand final decides it unless the losers-bracket
// champion (side B) wins it, in which case the reset match must be decided too.
export function isDoubleElimDecided(bracket: BracketView): boolean {
  const { grandFinal, reset } = splitDoubleElim(bracket)
  const gf = grandFinal?.match
  if (!gf || gf.status !== 'Completed' || !gf.outcome || !('winner' in gf.outcome)) return false
  if (gf.outcome.winner === 'A') return true
  const r = reset?.match
  return !!r && r.status === 'Completed' && !!r.outcome && 'winner' in r.outcome
}

export function doubleElimChampion(bracket: BracketView): string | null {
  if (!isDoubleElimDecided(bracket)) return null
  const { grandFinal, reset } = splitDoubleElim(bracket)
  const o = grandFinal?.match?.outcome
  const gfSide = o && 'winner' in o ? o.winner : null
  return winnerName(gfSide === 'A' ? grandFinal : reset)
}