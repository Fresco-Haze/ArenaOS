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
  const { main, thirdPlace } = splitThirdPlace(bracket)
  const groups = groupByRound(main)
  if (groups.length === 0) return false
  const final = groups[groups.length - 1]
  const finalDone = final.nodes.length === 1 && final.nodes[0].match?.status === 'Completed'
  const thirdDone = thirdPlace === null || thirdPlace.match?.status === 'Completed'
  return finalDone && thirdDone
}