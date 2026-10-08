import { useState } from 'react'
import { ApiError } from '../api'
import EFootballResultDialog from './EFootballResultDialog'
import WinnerDialog from './WinnerDialog'
import { participantName } from '../lib/participants'
import { startMatch, setSchedule } from '../lib/tournamentActions'
import type { BracketNode, TournamentFormat } from '../model'

function toLocalInput(iso: string | null): string {
  if (!iso) return ''
  const d = new Date(iso)
  const pad = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`
}

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
  const [correctScoreOpen, setCorrectScoreOpen] = useState(false)
  const [correctWinnerOpen, setCorrectWinnerOpen] = useState(false)
  const [when, setWhen] = useState(toLocalInput(node.match?.scheduledStart ?? null))

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

  async function handleSchedule(clear: boolean) {
    setBusy(true)
    setError(null)
    try {
      await setSchedule(matchId, clear || when === '' ? null : new Date(when).toISOString())
      if (clear) setWhen('')
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
      {match.status === 'Completed' && match.outcome && (
        <p className="muted">
          {'winner' in match.outcome
            ? `${match.outcome.winner === 'A' ? nameA : nameB} ${
                match.outcome.type === 'Winner' ? 'won' : match.outcome.type === 'Forfeit' ? 'advanced (forfeit)' : 'advanced (disqualification)'
              }`
            : match.outcome.type}
          {node.score ? ` (${node.score.a}-${node.score.b})` : ''}
        </p>
      )}
      {error && <p role="alert" className="form-error">{error}</p>}
      {match.status === 'Scheduled' && (
        <>
          <button onClick={handleStart} disabled={busy}>
            {busy ? 'Starting' : 'Start match'}
          </button>
          {match.scheduledStart && (
            <p className="muted">Starts {new Date(match.scheduledStart).toLocaleString()}</p>
          )}
          <details className="schedule-details"><summary>Set start time</summary><div className="match-actions-buttons">
            <input
              type="datetime-local"
              value={when}
              onChange={(e) => setWhen(e.target.value)}
              aria-label="Match start time"
            />
            <button onClick={() => void handleSchedule(false)} disabled={busy || when === ''}>
              Set time
            </button>
            {match.scheduledStart && (
              <button onClick={() => void handleSchedule(true)} disabled={busy}>
                Clear time
              </button>
            )}
          </div></details>
        </>
      )}
      {match.status === 'InProgress' && (
        <div className="match-actions-buttons">
          <button className="btn-primary" onClick={() => setWinnerDialogOpen(true)}>Declare result</button>
          <button onClick={() => setScoreDialogOpen(true)}>Record score</button>
        </div>
      )}
      {match.status === 'Completed' && format !== 'RoundRobin' && (
        <>
          <div className="match-actions-buttons">
            <button onClick={() => setCorrectScoreOpen(true)}>Correct score</button>
            <button onClick={() => setCorrectWinnerOpen(true)}>Correct result</button>
          </div>
          <EFootballResultDialog
            key={`correct-score-${node.score?.a ?? 'x'}-${node.score?.b ?? 'x'}`}
            open={correctScoreOpen}
            mode="correct"
            initial={node.score ?? undefined}
            matchId={matchId}
            nameA={nameA}
            nameB={nameB}
            format={format}
            onDone={onDone}
            onClose={() => setCorrectScoreOpen(false)}
          />
          <WinnerDialog
            open={correctWinnerOpen}
            mode="correct"
            matchId={matchId}
            nameA={nameA}
            nameB={nameB}
            format={format}
            onDone={onDone}
            onClose={() => setCorrectWinnerOpen(false)}
          />
        </>
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