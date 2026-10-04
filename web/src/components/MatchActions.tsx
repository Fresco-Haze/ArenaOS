import { useState } from 'react'
import { ApiError } from '../api'
import EFootballResultDialog from './EFootballResultDialog'
import WinnerDialog from './WinnerDialog'
import { participantName } from '../lib/participants'
import { startMatch } from '../lib/tournamentActions'
import type { BracketNode, TournamentFormat } from '../model'

export default function MatchActions({
  node,
  format,
  onDone,
}: {
  node: BracketNode
  format: TournamentFormat
  onDone: () => Promise<void>
}) {
  const { match } = node
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [scoreDialogOpen, setScoreDialogOpen] = useState(false)
  const [winnerDialogOpen, setWinnerDialogOpen] = useState(false)

  if (!match) return null
  const matchId = match.matchId

  const nameA = participantName(match.competitorA)
  const nameB = participantName(match.competitorB)

  async function handleStart() {
    setBusy(true)
    setError(null)
    try {
      await startMatch(matchId)
      await onDone()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="match-actions">
      <p className="match-players">{nameA} vs {nameB}</p>
      {error && <p role="alert" className="form-error">{error}</p>}
      {match.status === 'Scheduled' && (
        <button onClick={handleStart} disabled={busy}>
          {busy ? 'Starting' : 'Start match'}
        </button>
      )}
      {match.status === 'InProgress' && (
        <div className="match-actions-buttons">
          <button onClick={() => setScoreDialogOpen(true)}>Record score</button>
          <button onClick={() => setWinnerDialogOpen(true)}>Declare result</button>
        </div>
      )}
      <EFootballResultDialog
        open={scoreDialogOpen}
        matchId={match.matchId}
        nameA={nameA}
        nameB={nameB}
        format={format}
        onDone={onDone}
        onClose={() => setScoreDialogOpen(false)}
      />
      <WinnerDialog
        open={winnerDialogOpen}
        matchId={matchId}
        nameA={nameA}
        nameB={nameB}
        format={format}
        onDone={onDone}
        onClose={() => setWinnerDialogOpen(false)}
      />
    </div>
  )
}