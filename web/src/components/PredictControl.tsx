import { useState } from 'react'
import { ApiError } from '../api'
import { participantName } from '../lib/participants'
import { usePredictions } from '../lib/predictionContext'
import type { PredictionPick } from '../lib/predictions'
import type { BracketNode } from '../model'

type MatchT = NonNullable<BracketNode['match']>
type Verdict = 'correct' | 'wrong' | 'void' | 'pending'

// Display only: the server computes the real scores for the leaderboard.
function verdict(match: MatchT, pick: PredictionPick): Verdict {
  if (match.status === 'Cancelled') return 'void'
  if (match.status !== 'Completed' || !match.outcome) return 'pending'
  const o = match.outcome
  if ('winner' in o) return o.winner === pick ? 'correct' : 'wrong'
  if (o.type === 'Draw') return pick === 'Draw' ? 'correct' : 'wrong'
  return 'void'
}

export default function PredictControl({ node }: { node: BracketNode }) {
  const ctx = usePredictions()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const match = node.match
  if (!ctx || !ctx.active || !match) return null

  const mine = ctx.picks.get(match.matchId)
  const nameA = participantName(match.competitorA)
  const nameB = participantName(match.competitorB)
  const label = (p: PredictionPick) => (p === 'A' ? nameA : p === 'B' ? nameB : 'Draw')

  const choose = async (p: PredictionPick) => {
    setBusy(true)
    setError(null)
    try {
      await ctx.pick(match.matchId, p)
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  if (match.status === 'Scheduled' && ctx.canPick) {
    const options: PredictionPick[] = ctx.isRoundRobin ? ['A', 'B', 'Draw'] : ['A', 'B']
    return (
      <div className="predict" role="group" aria-label="Predict the winner">
        <span className="predict-label muted">Predict:</span>
        {options.map((p) => (
          <button
            key={p}
            type="button"
            className={'predict-btn' + (mine === p ? ' predict-on' : '')}
            aria-pressed={mine === p}
            disabled={busy}
            onClick={() => void choose(p)}
          >
            {label(p)}
          </button>
        ))}
        {error && <span role="alert" className="form-error">{error}</span>}
      </div>
    )
  }

  if (mine) {
    const v = verdict(match, mine)
    return (
      <p className="predict-result muted">
        Your pick: {label(mine)}
        {v === 'correct' && <span className="predict-ok"> {'\u2713'}<span className="sr-only"> correct</span></span>}
        {v === 'wrong' && <span className="predict-bad"> {'\u2717'}<span className="sr-only"> wrong</span></span>}
      </p>
    )
  }
  return null
}
