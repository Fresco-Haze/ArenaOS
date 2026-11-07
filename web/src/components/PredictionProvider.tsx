import { useState } from 'react'
import type { ReactNode } from 'react'
import { Link } from 'react-router'
import { useAuth } from '../auth/context'
import { useApi } from '../hooks/useApi'
import type { BracketView, Tournament } from '../model'
import PredictPanel from './PredictPanel'
import { PredictionContext } from '../lib/predictionContext'
import type { PredictionState } from '../lib/predictionContext'
import { PredictionList, submitPrediction } from '../lib/predictions'
import type { PredictionPick } from '../lib/predictions'

type Props = {
  tournament: Tournament
  viewerIsOwner: boolean
  viewerIsRegistered: boolean
  bracket: BracketView
  children: ReactNode
}

// Picks are open while the tournament is running. Matches exist from RegistrationClosed on.
const PICKABLE: readonly string[] = ['RegistrationClosed', 'InProgress']
const HAS_MATCHES: readonly string[] = ['RegistrationClosed', 'InProgress', 'Paused', 'Completed']

function ActiveProvider({ tournament, bracket, children }: { tournament: Tournament; bracket: BracketView; children: ReactNode }) {
  const server = useApi(`/tournaments/${tournament.tournamentId}/predictions`, PredictionList)
  const [local, setLocal] = useState<ReadonlyMap<number, PredictionPick>>(new Map())

  const picks = new Map<number, PredictionPick>()
  for (const p of server.data ?? []) picks.set(p.matchId, p.pick)
  for (const [matchId, pick] of local) picks.set(matchId, pick)

  const value: PredictionState = {
    active: true,
    canPick: PICKABLE.includes(tournament.state),
    isRoundRobin: tournament.format === 'RoundRobin',
    picks,
    pick: async (matchId, pick) => {
      await submitPrediction(matchId, pick)
      setLocal((prev) => new Map(prev).set(matchId, pick))
    },
  }
  return (
    <PredictionContext.Provider value={value}>
      <PredictPanel bracket={bracket} />
      {children}
    </PredictionContext.Provider>
  )
}

export default function PredictionProvider({ tournament, viewerIsOwner, viewerIsRegistered, bracket, children }: Props) {
  const { user } = useAuth()
  if (tournament.kind !== 'Bracket' || !HAS_MATCHES.includes(tournament.state)) return <>{children}</>
  if (!user) {
    if (!PICKABLE.includes(tournament.state)) return <>{children}</>
    return (
      <>
        <p className="muted">
          <Link to={`/login?next=/tournaments/${tournament.tournamentId}`}>Sign in</Link> to predict the winners.
        </p>
        {children}
      </>
    )
  }
  if (viewerIsOwner || viewerIsRegistered) return <>{children}</>
  return <ActiveProvider tournament={tournament} bracket={bracket}>{children}</ActiveProvider>
}
