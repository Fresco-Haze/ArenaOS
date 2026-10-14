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
  if (bracket.format === 'RoundRobin') {
    const played = bracket.nodes.filter((n) => n.match)
    return played.length > 0 && played.every((n) => n.match?.status === 'Completed')
  }
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
export type Placement = { place: string; names: string[] }

function slotName(slot: Slot): string | null {
  return slot.type === 'Filled' ? participantName(slot.participant) : null
}

// Winner and loser names of a completed match node, or null if it has no decided match.
function decided(node: BracketNode | null | undefined): { winner: string; loser: string } | null {
  const m = node?.match
  if (!node || !m || m.status !== 'Completed' || !m.outcome || !('winner' in m.outcome)) return null
  const a = slotName(node.slotA)
  const b = slotName(node.slotB)
  if (a === null || b === null) return null
  return m.outcome.winner === 'A' ? { winner: a, loser: b } : { winner: b, loser: a }
}

function singleElimPlacements(bracket: BracketView): Placement[] {
  const { main, thirdPlace } = splitThirdPlace(bracket)
  const groups = groupByRound(main)
  if (groups.length === 0) return []
  const final = groups[groups.length - 1]
  if (final.nodes.length !== 1) return []
  const f = decided(final.nodes[0])
  if (!f) return []
  const out: Placement[] = [
    { place: '1st', names: [f.winner] },
    { place: '2nd', names: [f.loser] },
  ]
  const t = decided(thirdPlace)
  if (t) {
    out.push({ place: '3rd', names: [t.winner] }, { place: '4th', names: [t.loser] })
  } else if (thirdPlace === null && groups.length >= 2) {
    const semiLosers = groups[groups.length - 2].nodes
      .map((n) => decided(n)?.loser)
      .filter((x): x is string => !!x)
    if (semiLosers.length > 0) {
      out.push({ place: semiLosers.length > 1 ? '3rd (shared)' : '3rd', names: semiLosers })
    }
  }
  return out
}

function doubleElimPlacements(bracket: BracketView): Placement[] {
  if (!isDoubleElimDecided(bracket)) return []
  const { losers, grandFinal, reset } = splitDoubleElim(bracket)
  const gfOutcome = grandFinal?.match?.outcome
  const gfSide = gfOutcome && 'winner' in gfOutcome ? gfOutcome.winner : null
  const decisive = decided(gfSide === 'A' ? grandFinal : reset)
  if (!decisive) return []
  const out: Placement[] = [
    { place: '1st', names: [decisive.winner] },
    { place: '2nd', names: [decisive.loser] },
  ]
  // Third is the loser of the losers final; fourth is the loser of the single match before it.
  // A bye is not a match, so with few players there may be no fourth place.
  const lGroups = groupByRound(losers)
  const last = lGroups[lGroups.length - 1]
  if (last && last.nodes.length === 1) {
    const lf = decided(last.nodes[0])
    if (lf) {
      out.push({ place: '3rd', names: [lf.loser] })
      const prev = lGroups[lGroups.length - 2]
      if (prev && prev.nodes.length === 1) {
        const pl = decided(prev.nodes[0])
        if (pl) out.push({ place: '4th', names: [pl.loser] })
      }
    }
  }
  return out
}

export function placements(bracket: BracketView): Placement[] {
  if (!isBracketDecided(bracket)) return []
  return bracket.grandFinalNodeId != null ? doubleElimPlacements(bracket) : singleElimPlacements(bracket)
}

export const TREE = { cardH: 98, colW: 220, colGap: 40, rowGap: 16, head: 32 }

export type TreeLayout = {
  nodes: { node: BracketNode; x: number; cy: number }[]
  links: { key: number; d: string }[]
  heads: { round: number; x: number }[]
  width: number
  height: number
}

// Positions come from the links only. Returns null (caller falls back to the
// plain columns) unless every link is present and consistent.
export function layoutSingleElim(main: BracketNode[], linksAvailable: boolean | null | undefined): TreeLayout | null {
  if (!linksAvailable || main.length === 0) return null
  const byId = new Map<number, BracketNode>()
  for (const n of main) byId.set(n.nodeId, n)
  if (byId.size !== main.length) return null

  const feeders = new Map<number, { A?: number; B?: number }>()
  const roots: BracketNode[] = []
  for (const n of main) {
    const w = n.winnerTo
    if (!w) {
      roots.push(n)
      continue
    }
    const target = byId.get(w.node)
    if (!target || target.round !== n.round + 1) return null
    const f = feeders.get(target.nodeId) ?? {}
    if (f[w.slot] !== undefined) return null
    f[w.slot] = n.nodeId
    feeders.set(target.nodeId, f)
  }
  if (roots.length !== 1) return null

  const pitch = TREE.cardH + TREE.rowGap
  const cyOf = new Map<number, number>()
  let leaves = 0
  let seen = 0
  const visit = (n: BracketNode): boolean => {
    seen++
    const f = feeders.get(n.nodeId)
    if (!f) {
      if (n.round !== 1) return false
      cyOf.set(n.nodeId, TREE.head + leaves * pitch + TREE.cardH / 2)
      leaves++
      return true
    }
    const a = f.A !== undefined ? byId.get(f.A) : undefined
    const b = f.B !== undefined ? byId.get(f.B) : undefined
    if (!a || !b) return false
    if (!visit(a) || !visit(b)) return false
    cyOf.set(n.nodeId, ((cyOf.get(a.nodeId) as number) + (cyOf.get(b.nodeId) as number)) / 2)
    return true
  }
  if (!visit(roots[0]) || seen !== main.length) return null

  const xOf = (round: number) => (round - 1) * (TREE.colW + TREE.colGap)
  const rounds = [...new Set(main.map((n) => n.round))].sort((a, b) => a - b)
  const links: { key: number; d: string }[] = []
  for (const n of main) {
    const w = n.winnerTo
    if (!w) continue
    const t = byId.get(w.node) as BracketNode
    const x1 = xOf(n.round) + TREE.colW
    const xm = x1 + TREE.colGap / 2
    const x2 = xOf(t.round)
    const y1 = cyOf.get(n.nodeId) as number
    const y2 = cyOf.get(t.nodeId) as number
    links.push({ key: n.nodeId, d: `M${x1} ${y1}H${xm}V${y2}H${x2}` })
  }
  return {
    nodes: main.map((n) => ({ node: n, x: xOf(n.round), cy: cyOf.get(n.nodeId) as number })),
    links,
    heads: rounds.map((r) => ({ round: r, x: xOf(r) })),
    width: xOf(rounds[rounds.length - 1]) + TREE.colW,
    height: TREE.head + leaves * pitch - TREE.rowGap,
  }
}
