import { useState } from 'react'
import { ApiError } from '../api'
import ConfirmDialog from './ConfirmDialog'
import { participantName } from '../lib/participants'
import { startMatch, recordResult } from '../lib/tournamentActions'
import type { BracketNode } from '../model'

export default function MatchActions({ node, onDone }: { node: BracketNode; onDone: () => Promise<void> }) {
  const { match } = node
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [confirmSide, setConfirmSide] = useState<'A' | 'B' | null>(null)

  if (!match) return null

  const nameA = participantName(match.competitorA)
  const nameB = participantName(match.competitorB)

  async function handleStart() {
    setBusy(true)
    setError(null)
    try {
      await startMatch(match.matchId)
      await onDone()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  async function handleConfirmWinner() {
    if (!confirmSide) return
    await recordResult(match.matchId, confirmSide)
    await onDone()
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
          <button onClick={() => setConfirmSide('A')}>{nameA} wins</button>
          <button onClick={() => setConfirmSide('B')}>{nameB} wins</button>
        </div>
      )}
      <ConfirmDialog
        open={confirmSide !== null}
        title="Confirm result"
        confirmLabel="Confirm result"
        onConfirm={handleConfirmWinner}
        onClose={() => setConfirmSide(null)}
      >
        <p>Confirm: {confirmSide === 'A' ? nameA : nameB} wins against {confirmSide === 'A' ? nameB : nameA}?</p>
        <p className="muted">Results can't be corrected in this version.</p>
      </ConfirmDialog>
    </div>
  )
}