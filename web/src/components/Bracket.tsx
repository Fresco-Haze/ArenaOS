import { buildNodeLabels, champion, groupByRound, roundName, slotLabel } from '../lib/bracket'
import type { BracketNode, BracketView } from '../model'

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
  return 'Waiting for players'
}

function SlotRow({ label, isWinner }: { label: string; isWinner: boolean }) {
  return (
    <div className={isWinner ? 'slot slot-winner' : 'slot'}>
      <span>{label}</span>
      {isWinner && <span className="slot-tag">Winner</span>}
    </div>
  )
}

function NodeCard({ node, nodeLabels }: { node: BracketNode; nodeLabels: Map<number, string> }) {
  const winSide = outcomeSide(node)
  return (
    <div className="match-card">
      <SlotRow label={slotLabel(node.slotA, nodeLabels)} isWinner={winSide === 'A'} />
      <SlotRow label={slotLabel(node.slotB, nodeLabels)} isWinner={winSide === 'B'} />
      <p className="match-status">{statusText(node)}</p>
    </div>
  )
}

export default function Bracket({ bracket }: { bracket: BracketView }) {
  const groups = groupByRound(bracket.nodes)
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
    </div>
  )
}