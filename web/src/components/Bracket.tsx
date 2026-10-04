import type { BracketNode, BracketView } from '../model'
import { buildNodeLabels, champion, groupByRound, roundName, slotLabel, splitThirdPlace } from '../lib/bracket'
import { buildDoubleElimLabels, doubleElimChampion, sectionRoundNames, splitDoubleElim } from '../lib/bracket'
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
        return 'Completed'
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

