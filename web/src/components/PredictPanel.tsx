import { usePredictions } from '../lib/predictionContext'
import { participantName } from '../lib/participants'
import type { BracketView } from '../model'
import PredictControl from './PredictControl'

// One row per match the viewer can still pick, plus every match they already picked.
export default function PredictPanel({ bracket }: { bracket: BracketView }) {
  const ctx = usePredictions()
  if (!ctx || !ctx.active) return null

  const rows = [...bracket.nodes]
    .filter((n) => {
      const m = n.match
      if (!m) return false
      if (ctx.picks.has(m.matchId)) return true
      return ctx.canPick && m.status === 'Scheduled'
    })
    .sort((a, b) => a.nodeId - b.nodeId)

  if (rows.length === 0) return null

  return (
    <section className="predict-panel" aria-labelledby="predict-heading">
      <h3 id="predict-heading" className="bracket-section-heading">Predict the winners</h3>
      <p className="muted">Free points, no money. Picks lock when a match starts.</p>
      <ul className="predict-list">
        {rows.map((n) => (
          <li key={n.nodeId} className="predict-row">
            {n.match && (
              <p className="predict-match">
                {participantName(n.match.competitorA)} vs {participantName(n.match.competitorB)}
              </p>
            )}
            <PredictControl node={n} />
          </li>
        ))}
      </ul>
    </section>
  )
}