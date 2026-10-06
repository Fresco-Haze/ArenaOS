import type { BracketView, Participant, Slot } from '../model'
import {
  buildDoubleElimLabels, buildNodeLabels, groupByRound, placements,
  sectionRoundNames, slotLabel, splitDoubleElim, splitThirdPlace,
} from './bracket'
import { participantName } from './participants'

function normalize(s: string): string {
  return s.trim().toLowerCase()
}

// Squad members can look themselves up too; they land on their team.
function searchNames(p: Participant): string[] {
  return p.type === 'Individual' ? [p.player] : [p.team.name, ...p.team.members]
}

// Exact match first (the backend is case-sensitive), then ignoring case, then partial.
export function findParticipants(participants: Participant[], query: string): Participant[] {
  const q = query.trim()
  if (q === '') return []
  const exact = participants.filter((p) => participantName(p) === q)
  if (exact.length === 1) return exact
  const n = normalize(q)
  const same = participants.filter((p) => searchNames(p).some((s) => normalize(s) === n))
  if (same.length > 0) return same
  return participants.filter((p) => searchNames(p).some((s) => normalize(s).includes(n)))
}

function nodeLabels(bracket: BracketView): Map<number, string> {
  if (bracket.grandFinalNodeId != null) {
    const { winners, losers, grandFinal, reset } = splitDoubleElim(bracket)
    const wg = groupByRound(winners)
    const lg = groupByRound(losers)
    return buildDoubleElimLabels(
      [
        { groups: wg, names: sectionRoundNames(wg.length, 'Winners') },
        { groups: lg, names: sectionRoundNames(lg.length, 'Losers') },
      ],
      grandFinal,
      reset,
    )
  }
  const { main, thirdPlace } = splitThirdPlace(bracket)
  const groups = groupByRound(main)
  const labels = buildNodeLabels(groups, groups.length)
  if (thirdPlace) labels.set(thirdPlace.nodeId, 'Third-place match')
  return labels
}

function holds(slot: Slot, name: string): boolean {
  return slot.type === 'Filled' && participantName(slot.participant) === name
}

export type PlayerStatus = { name: string; headline: string; details: string[] }

export function playerStatus(bracket: BracketView, participant: Participant): PlayerStatus {
  const name = participantName(participant)
  const roundRobin = bracket.format === 'RoundRobin'

  if (!roundRobin) {
    const place = placements(bracket).find((p) => p.names.includes(name))
    if (place) return { name, headline: `Placed ${place.place}. The tournament is over.`, details: [] }
  }

  const labels = nodeLabels(bracket)
  const mine = bracket.nodes
    .filter((n) => holds(n.slotA, name) || holds(n.slotB, name))
    .sort((a, b) => a.round - b.round || a.nodeId - b.nodeId)

  const pending: { playing: boolean; opponent: string; where: string | null; when: string | null }[] = []
  const waiting: { on: string; where: string | null }[] = []

  for (const n of mine) {
    const other = holds(n.slotA, name) ? n.slotB : n.slotA
    const where = roundRobin ? null : (labels.get(n.nodeId) ?? null)
    const m = n.match
    if (m && (m.status === 'Scheduled' || m.status === 'InProgress')) {
      pending.push({
        playing: m.status === 'InProgress',
        opponent: slotLabel(other, labels),
        where,
        when: m.scheduledStart,
      })
    } else if (!m && (other.type === 'AwaitingWinnerOf' || other.type === 'AwaitingLoserOf')) {
      waiting.push({ on: slotLabel(other, labels), where })
    }
  }

  if (pending.length > 0) {
    const [first, ...rest] = pending
    const details: string[] = []
    if (first.where) details.push(first.where)
    if (first.when) details.push(`Scheduled for ${new Date(first.when).toLocaleString()}`)
    for (const r of rest) details.push(`Also: against ${r.opponent}`)
    return {
      name,
      headline: first.playing ? `Playing now against ${first.opponent}` : `Next match: against ${first.opponent}`,
      details,
    }
  }

  if (waiting.length > 0) {
    const w = waiting[0]
    const details = [`Decided by: ${w.on}`]
    if (w.where) details.push(`Your match: ${w.where}`)
    return { name, headline: 'Waiting to find out your opponent', details }
  }

  if (roundRobin) return { name, headline: 'You have no more matches to play.', details: [] }
  if (mine.length === 0) return { name, headline: 'You are not in the bracket yet.', details: [] }
  return { name, headline: 'You are out of the tournament.', details: [] }
}