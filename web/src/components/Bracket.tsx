import type { BracketNode, BracketView } from '../model'
import { buildNodeLabels, champion, groupByRound, roundName, slotLabel, splitThirdPlace } from '../lib/bracket'
import { buildDoubleElimLabels, doubleElimChampion, placements, sectionRoundNames, splitDoubleElim } from '../lib/bracket'
import { isBracketDecided } from '../lib/bracket'
import { participantName } from '../lib/participants'
import type { RoundGroup } from '../lib/bracket'

function outcomeSide(node: BracketNode): 'A' | 'B' | null {
  const o = node.match?.outcome
  if (!o || !('winner' in o)) return null
  return o.winner
}

function statusText(node: BracketNode): string {
  if (node.match) {
    switch (node.match.status) {
      case 'Scheduled':
        return 'Scheduled'
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

function SlotRow({ label, isWinner, score }: { label: string; isWinner: boolean; score?: number }) {
  return (
    <div className={isWinner ? 'slot slot-winner' : 'slot'}>
      <span>{label}</span>
      <span className="slot-right">
        {isWinner && <span className="slot-tag">Winner</span>}
        {score !== undefined && <span className="slot-score">{score}</span>}
      </span>
    </div>
  )
}

function NodeCard({ node, nodeLabels }: { node: BracketNode; nodeLabels: Map<number, string> }) {
  const winSide = outcomeSide(node)
  return (
    <div className="match-card">
      <SlotRow label={slotLabel(node.slotA, nodeLabels)} isWinner={winSide === 'A'} score={node.score?.a} />
      <SlotRow label={slotLabel(node.slotB, nodeLabels)} isWinner={winSide === 'B'} score={node.score?.b} />
      <p className="match-status">{statusText(node)}</p>
    </div>
  )
}

function Standings({ bracket }: { bracket: BracketView }) {
  const list = placements(bracket)
  if (list.length === 0) return null
  return (
    <div className="standings">
      <h3 className="bracket-section-heading">Final standings</h3>
      {list.map((p) => (
        <div key={p.place} className="standing-row">
          <span className="standing-place">{p.place}</span>
          <span>{p.names.join(', ')}</span>
        </div>
      ))}
    </div>
  )
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
  const levelAtTop = rows.length > 1 && rows[0].points === rows[1].points
  const anyLevel = rows.some((r, i) => i > 0 && r.points === rows[i - 1].points)
  const labels = new Map<number, string>()

  return (
    <div>
      {decided && rows.length > 0 && !levelAtTop && (
        <p className="champion">Winner: {participantName(rows[0].participant)}</p>
      )}
      {decided && levelAtTop && <p className="muted">The top places are level on points.</p>}
      <h3 className="bracket-section-heading">Standings</h3>
      <table className="rr-table">
        <thead>
          <tr>
            <th>#</th>
            <th>Name</th>
            <th>Played</th>
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
                <td>{r.points}</td>
              </tr>
            )
          })}
        </tbody>
      </table>
      {anyLevel && (
        <p className="muted">
          Level on points: ordered by the results between them where possible. If they are still level, the order shown is not a ranking.
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
      {champ && <p className="champion">Champion: {champ}</p>}
      <Standings bracket={bracket} />
      <h3 className="bracket-section-heading">Winners bracket</h3>
      <RoundColumns groups={wGroups} names={wNames} nodeLabels={nodeLabels} />
      {lGroups.length > 0 && (
        <>
          <h3 className="bracket-section-heading">Losers bracket</h3>
          <RoundColumns groups={lGroups} names={lNames} nodeLabels={nodeLabels} />
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
export default function Bracket({ bracket }: { bracket: BracketView }) {
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

  return (
    <div>
      {champ && <p className="champion">Champion: {champ}</p>}
      <Standings bracket={bracket} />
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
      {thirdPlace && (
        <div className="third-place">
          <h3 className="bracket-round-heading">Third place</h3>
          <NodeCard node={thirdPlace} nodeLabels={nodeLabels} />
        </div>
      )}
    </div>
  )
}

