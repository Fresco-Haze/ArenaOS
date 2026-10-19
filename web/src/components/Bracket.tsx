import { createContext, useContext, useState } from 'react'
import { formatDateTime } from '../lib/dates'
import { layoutSection, layoutSingleElim, TREE } from '../lib/bracket'
import type { TreeLayout } from '../lib/bracket'
import { matchBadge } from '../badges'
import type { BracketNode, BracketView } from '../model'
import { buildNodeLabels, champion, groupByRound, roundName, slotLabel, splitThirdPlace } from '../lib/bracket'
import { buildDoubleElimLabels, doubleElimChampion, placements, sectionRoundNames, splitDoubleElim } from '../lib/bracket'
import { isBracketDecided } from '../lib/bracket'
import { participantName } from '../lib/participants'
import type { RoundGroup } from '../lib/bracket'
import ChampionBanner from './ChampionBanner'
import Tabs from './Tabs'
import { useMediaQuery } from '../hooks/useMediaQuery'

function outcomeSide(node: BracketNode): 'A' | 'B' | null {
  const o = node.match?.outcome
  if (!o || !('winner' in o)) return null
  return o.winner
}

function statusText(node: BracketNode): string {
  if (node.match) {
    switch (node.match.status) {
      case 'Scheduled':
        return node.match.scheduledStart ? `Scheduled for ${formatDateTime(node.match.scheduledStart)}` : 'Scheduled'
      case 'InProgress':
        return 'In progress'
      case 'Completed':
        return node.match.outcome?.type === 'Forfeit' ? 'Completed (forfeit)' : node.match.outcome?.type === 'Disqualification' ? 'Completed (disqualification)' : node.match.outcome?.type === 'Draw' ? 'Completed (draw)' : 'Completed'
      case 'Cancelled':
        return 'Cancelled'
    }
  }
  if (node.slotA.type === 'Bye' || node.slotB.type === 'Bye') return 'Bye'
  return 'Waiting for competitors'
}

function MatchStatus({ node }: { node: BracketNode }) {
  const text = statusText(node)
  const m = /^(Scheduled|Completed)( for .+| \(.+)$/.exec(text)
  const label = m ? m[1] : text
  const detail = m ? m[2].replace(/^ for /, '') : ''
  const tone = (node.match && matchBadge[node.match.status]) || 'badge-neutral'
  return (
    <>
      <span className={'badge ' + tone}>{label}</span>
      <span>{detail}</span>
    </>
  )
}
type CardState = 'waiting' | 'scheduled' | 'live' | 'completed' | 'bye'

function cardState(node: BracketNode): CardState {
  const m = node.match
  if (m) {
    if (m.status === 'InProgress') return 'live'
    if (m.status === 'Completed') return 'completed'
    if (m.status === 'Scheduled') return 'scheduled'
    return 'waiting'
  }
  if (node.slotA.type === 'Bye' || node.slotB.type === 'Bye') return 'bye'
  return 'waiting'
}

// Undo shortLabel for the hover title on waiting slots.
function fullLabel(s: string): string {
  return s.replace(/\bWB\b/, 'Winners').replace(/\bLB\b/, 'Losers').replace(/ R(\d+)/, ' round $1').replace(/ M(\d+)/, ' match $1')
}
function CheckIcon() {
  return (
    <svg className="slot-check" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path d="M3 8.5l3.2 3L13 4.5" />
    </svg>
  )
}
function SlotRow({ label, isWinner, isLoser, pending, score }: { label: string; isWinner: boolean; isLoser: boolean; pending: boolean; score?: number }) {
  const cls = 'slot' + (isWinner ? ' slot-winner' : '') + (isLoser ? ' slot-loser' : '') + (pending ? ' slot-pending' : '')
  return (
    <div className={cls}>
      <span className="slot-name" title={pending ? fullLabel(label) : undefined}>{isWinner && <span className="sr-only">Winner: </span>}{label}</span>
      {score !== undefined ? <span className="slot-score num">{score}</span> : isWinner ? <CheckIcon /> : null}
    </div>
  )
}

function NodeCard({ node, nodeLabels }: { node: BracketNode; nodeLabels: Map<number, string> }) {
  const winSide = outcomeSide(node)
  const state = cardState(node)
  const cancelled = useContext(CancelledContext)
  const stopped = cancelled && (state === 'live' || state === 'scheduled')
  if (state === 'bye') {
    const filled = [node.slotA, node.slotB].find((s) => s.type === 'Filled')
    return (
      <div className="match-card match-bye">
        <span className="slot-name">{filled && filled.type === 'Filled' ? participantName(filled.participant) : 'Bye'}</span>
        {filled && <span>Bye</span>}
      </div>
    )
  }
  const done = state === 'completed'
  const pendingA = node.slotA.type === 'AwaitingWinnerOf' || node.slotA.type === 'AwaitingLoserOf'
  const pendingB = node.slotB.type === 'AwaitingWinnerOf' || node.slotB.type === 'AwaitingLoserOf'
  return (
    <div className={'match-card match-' + (stopped ? 'waiting' : state)}>
      <SlotRow label={slotLabel(node.slotA, nodeLabels)} isWinner={winSide === 'A'} isLoser={done && winSide === 'B'} pending={pendingA} score={node.score?.a} />
      <SlotRow label={slotLabel(node.slotB, nodeLabels)} isWinner={winSide === 'B'} isLoser={done && winSide === 'A'} pending={pendingB} score={node.score?.b} />
      <p className="match-status">
        {state === 'live' && !stopped && <span className="live-dot" aria-hidden="true" />}
        {stopped ? <span className="badge badge-danger">Cancelled</span> : <MatchStatus node={node} />}
      </p>
    </div>
  )
}
function Standings({ bracket }: { bracket: BracketView }) {
  const list = placements(bracket)
  if (list.length === 0) return null
  return (
    <div className="standings">
      <h3 className="bracket-section-heading">Final standings</h3>
      {list.map((p, i) => (
        <div key={p.place} className={i === 0 ? 'standing-row standing-first' : 'standing-row'}>
          <span className="standing-place">{p.place}</span>
          <span>{p.names.join(', ')}</span>
        </div>
      ))}
    </div>
  )
}
type StandingRow = NonNullable<BracketView['standings']>[number]

// Same table position: level on points, goal difference and goals scored.
function sameRank(a: StandingRow, b: StandingRow): boolean {
  return a.points === b.points && a.goalDifference === b.goalDifference && a.goalsFor === b.goalsFor
}

function signed(n: number): string {
  return n > 0 ? `+${n}` : String(n)
}
function RoundRobinView({ bracket }: { bracket: BracketView }) {
  const nodes = [...bracket.nodes].sort((a, b) => a.nodeId - b.nodeId)
  const rows = bracket.standings ?? []
  const decided = isBracketDecided(bracket)
  const played = new Map<string, number>()
  for (const n of nodes) {
    if (n.match?.status !== 'Completed') continue
    for (const slot of [n.slotA, n.slotB]) {
      if (slot.type === 'Filled') {
        const name = participantName(slot.participant)
        played.set(name, (played.get(name) ?? 0) + 1)
      }
    }
  }
  const levelAtTop = rows.length > 1 && sameRank(rows[0], rows[1])
  const anyLevel = rows.some((r, i) => i > 0 && sameRank(r, rows[i - 1]))
  const labels = new Map<number, string>()

  return (
    <div>
      {decided && rows.length > 0 && !levelAtTop && (
        <ChampionBanner label="Winner" name={participantName(rows[0].participant)} />
      )}
      {decided && levelAtTop && <p className="muted">The top places are level on points, goal difference and goals scored.</p>}
      <h3 className="bracket-section-heading">Standings</h3>
      <div className="rr-scroll">
      <table className="rr-table">
        <thead>
          <tr>
            <th>#</th>
            <th>Name</th>
            <th>Played</th>
            <th>GF</th>
            <th>GA</th>
            <th>GD</th>
            <th>Pts</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => {
            const name = participantName(r.participant)
            return (
              <tr key={name}>
                <td>{i + 1}</td>
                <td>{name}</td>
                <td>{played.get(name) ?? 0}</td>
                <td>{r.goalsFor}</td>
                <td>{r.goalsAgainst}</td>
                <td>{signed(r.goalDifference)}</td>
                <td>{r.points}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
      </div>
      {(bracket.unscoredMatches ?? 0) > 0 && (
        <p className="muted">
          Goals exclude {bracket.unscoredMatches} completed {bracket.unscoredMatches === 1 ? 'match' : 'matches'} recorded without a score.
        </p>
      )}
      {anyLevel && (
        <p className="muted">
          Level on points, goal difference and goals scored: ordered by the results between them where possible. If they are still level, the order shown is not a ranking.
        </p>
      )}
      <h3 className="bracket-section-heading">Matches</h3>
      <div className="rr-matches">
        {nodes.map((n) => (
          <NodeCard key={n.nodeId} node={n} nodeLabels={labels} />
        ))}
      </div>
    </div>
  )
}
function RoundColumns({ groups, names, nodeLabels }: { groups: RoundGroup[]; names: string[]; nodeLabels: Map<number, string> }) {
  return (
    <div className="bracket-scroll">
      <div className="bracket">
        {groups.map((g, i) => (
          <div key={g.round} className="bracket-column">
            <h3 className="bracket-round-heading">{names[i]}</h3>
            <div className="bracket-matches">
              {g.nodes.map((n) => (
                <NodeCard key={n.nodeId} node={n} nodeLabels={nodeLabels} />
              ))}
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}

function SectionView({ nodes, groups, names, nodeLabels, linksAvailable }: { nodes: BracketNode[]; groups: RoundGroup[]; names: string[]; nodeLabels: Map<number, string>; linksAvailable: boolean | null | undefined }) {
  const tree = layoutSection(nodes, linksAvailable)
  if (!tree) return <RoundColumns groups={groups} names={names} nodeLabels={nodeLabels} />
  return <TreeBracket tree={tree} totalRounds={0} names={names} nodeLabels={nodeLabels} />
}
function DoubleElimBracket({ bracket }: { bracket: BracketView }) {
  const { winners, losers, grandFinal, reset } = splitDoubleElim(bracket)
  const wGroups = groupByRound(winners)
  const lGroups = groupByRound(losers)
  const wNames = sectionRoundNames(wGroups.length, 'Winners')
  const lNames = sectionRoundNames(lGroups.length, 'Losers')
  const nodeLabels = buildDoubleElimLabels(
    [{ groups: wGroups, names: wNames }, { groups: lGroups, names: lNames }],
    grandFinal,
    reset,
  )
  const champ = doubleElimChampion(bracket)
  // An unplayed reset is BYE vs BYE: nothing to show.
  const showReset = reset !== null && !(reset.slotA.type === 'Bye' && reset.slotB.type === 'Bye')

  return (
    <div>
      {champ && <ChampionBanner name={champ} />}
      <Standings bracket={bracket} />
      <h3 className="bracket-section-heading">Winners bracket</h3>
      <SectionView nodes={winners} groups={wGroups} names={wNames} nodeLabels={nodeLabels} linksAvailable={bracket.linksAvailable} />
      {lGroups.length > 0 && (
        <>
          <h3 className="bracket-section-heading">Losers bracket</h3>
          <SectionView nodes={losers} groups={lGroups} names={lNames} nodeLabels={nodeLabels} linksAvailable={bracket.linksAvailable} />
        </>
      )}
      {grandFinal && (
        <div className="bracket-final">
          <h3 className="bracket-section-heading">Grand final</h3>
          <NodeCard node={grandFinal} nodeLabels={nodeLabels} />
          {showReset && reset && (
            <>
              <h3 className="bracket-round-heading">Reset match</h3>
              <p className="muted">Played only if the losers-bracket champion wins the grand final.</p>
              <NodeCard node={reset} nodeLabels={nodeLabels} />
            </>
          )}
        </div>
      )}
    </div>
  )
}
function TreeBracket({ tree, totalRounds, names, nodeLabels }: { tree: TreeLayout; totalRounds: number; names?: string[]; nodeLabels: Map<number, string> }) {
  return (
    <div className="bracket-scroll">
      <div className="bracket-tree" style={{ width: tree.width, height: tree.height }}>
        {tree.heads.map((h, i) => (
          <h3 key={h.round} className="bracket-round-heading" style={{ left: h.x, width: TREE.colW }}>
            {names ? names[i] : roundName(h.round, totalRounds)}
          </h3>
        ))}
        <svg className="bracket-links" width={tree.width} height={tree.height} aria-hidden="true">
          {tree.links.map((l) => (
            <path key={l.key} d={l.d} />
          ))}
        </svg>
        {tree.nodes.map((t) => (
          <div
            key={t.node.nodeId}
            className="bracket-node"
            style={{ left: t.x, top: t.cy - TREE.cardH / 2, width: TREE.colW, height: TREE.cardH }}
          >
            <NodeCard node={t.node} nodeLabels={nodeLabels} />
          </div>
        ))}
      </div>
    </div>
  )
}
// Phones, single elimination: one round at a time. Same NodeCard, no bracket logic.
function RoundSwitcher({
  groups,
  totalRounds,
  nodeLabels,
  thirdPlace,
}: {
  groups: RoundGroup[]
  totalRounds: number
  nodeLabels: Map<number, string>
  thirdPlace: BracketNode | null
}) {
  const [picked, setPicked] = useState<number | null>(null)
  const last = groups[groups.length - 1]
  const current = groups.find((g) =>
    g.nodes.some((n) => {
      const s = cardState(n)
      return s !== 'completed' && s !== 'bye'
    }),
  )
  const round =
    picked !== null && groups.some((g) => g.round === picked) ? picked : (current ?? last).round
  const group = groups.find((g) => g.round === round) ?? last
  return (
    <div>
      <Tabs<string>
        label="Bracket rounds"
        active={String(round)}
        onChange={(id) => setPicked(Number(id))}
        tabs={groups.map((g) => ({ id: String(g.round), label: roundName(g.round, totalRounds) }))}
      />
      <div role="tabpanel" id={'panel-' + round} aria-labelledby={'tab-' + round} className="round-list">
        {group.nodes.map((n) => (
          <NodeCard key={n.nodeId} node={n} nodeLabels={nodeLabels} />
        ))}
        {thirdPlace && group.round === last.round && (
          <>
            <h3 className="bracket-round-heading">Third place</h3>
            <NodeCard node={thirdPlace} nodeLabels={nodeLabels} />
          </>
        )}
      </div>
    </div>
  )
}

const CancelledContext = createContext(false)

export default function Bracket({ bracket, tournamentState }: { bracket: BracketView; tournamentState?: string }) {
  return (
    <CancelledContext.Provider value={tournamentState === 'Cancelled'}>
      <BracketInner bracket={bracket} />
    </CancelledContext.Provider>
  )
}

function BracketInner({ bracket }: { bracket: BracketView }) {
  const phone = useMediaQuery('(max-width: 600px)')
  if (bracket.grandFinalNodeId != null) return <DoubleElimBracket bracket={bracket} />
  if (bracket.format === 'RoundRobin') return <RoundRobinView bracket={bracket} />
  const { main, thirdPlace } = splitThirdPlace(bracket)
  const groups = groupByRound(main)
  if (groups.length === 0) {
    return <p className="muted">The bracket has not been generated yet.</p>
  }

  const totalRounds = Math.max(...groups.map((g) => g.round))
  const nodeLabels = buildNodeLabels(groups, totalRounds)
  const champ = champion(groups)
  const tree = layoutSingleElim(main, bracket.linksAvailable)

  return (
    <div>
      {champ && <ChampionBanner name={champ} />}
      <Standings bracket={bracket} />
      {phone ? (
        <RoundSwitcher groups={groups} totalRounds={totalRounds} nodeLabels={nodeLabels} thirdPlace={thirdPlace} />
      ) : tree ? (
        <TreeBracket tree={tree} totalRounds={totalRounds} nodeLabels={nodeLabels} />
      ) : (
      <div className="bracket-scroll">
        <div className="bracket">
          {groups.map((g) => (
            <div key={g.round} className="bracket-column">
              <h3 className="bracket-round-heading">{roundName(g.round, totalRounds)}</h3>
              <div className="bracket-matches">
                {g.nodes.map((n) => (
                  <NodeCard key={n.nodeId} node={n} nodeLabels={nodeLabels} />
                ))}
              </div>
            </div>
          ))}
        </div>
      </div>
      )}
      {!phone && thirdPlace && (
        <div className="third-place">
          <h3 className="bracket-round-heading">Third place</h3>
          <NodeCard node={thirdPlace} nodeLabels={nodeLabels} />
        </div>
      )}
    </div>
  )
}

