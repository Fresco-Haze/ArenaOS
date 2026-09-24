import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import ConfirmDialog from './ConfirmDialog'
import MatchActions from './MatchActions'
import { actionableMatches, isFinalDecided } from '../lib/bracket'
import {
  publish, openRegistration, addParticipant, closeRegistration,
  generateBracket, startTournament, completeTournament, cancelTournament,
} from '../lib/tournamentActions'
import type { BracketView, Tournament } from '../model'

function ActionButton({ label, busyLabel, onRun }: { label: string; busyLabel?: string; onRun: () => Promise<void> }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handle() {
    setBusy(true)
    setError(null)
    try {
      await onRun()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="action-item">
      <button onClick={handle} disabled={busy}>{busy ? (busyLabel ?? 'Working') : label}</button>
      {error && <p role="alert" className="form-error">{error}</p>}
    </div>
  )
}

function AddParticipantForm({ tournamentId, onDone }: { tournamentId: number; onDone: () => Promise<void> }) {
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await addParticipant(tournamentId, name)
      setName('')
      await onDone()
    } catch (err) {
      console.error('addParticipant failed:', err)
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="inline-form">
      <label>
        Player name
        <input value={name} onChange={(e) => setName(e.target.value)} required />
      </label>
      {error && <p role="alert" className="form-error">{error}</p>}
      <button type="submit" disabled={busy}>{busy ? 'Adding' : 'Add player'}</button>
    </form>
  )
}

function CancelAction({ tournamentId, onDone }: { tournamentId: number; onDone: () => Promise<void> }) {
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState('')

  return (
    <>
      <button onClick={() => setOpen(true)}>Cancel tournament</button>
      <ConfirmDialog
        open={open}
        title="Cancel tournament"
        confirmLabel="Cancel tournament"
        onConfirm={async () => {
          await cancelTournament(tournamentId, reason)
          setReason('')
          await onDone()
        }}
        onClose={() => setOpen(false)}
      >
        <label>
          Reason
          <textarea value={reason} onChange={(e) => setReason(e.target.value)} required />
        </label>
      </ConfirmDialog>
    </>
  )
}

function CloseRegistrationAction({ tournamentId, participantCount, onDone }:
  { tournamentId: number; participantCount: number; onDone: () => Promise<void> }) {
  const [open, setOpen] = useState(false)
  return (
    <>
      <button onClick={() => setOpen(true)}>Close registration</button>
      <ConfirmDialog
        open={open}
        title="Close registration"
        confirmLabel="Close registration"
        onConfirm={async () => { await closeRegistration(tournamentId); await onDone() }}
        onClose={() => setOpen(false)}
      >
        <p>Close registration with {participantCount} players? This can't be reopened.</p>
      </ConfirmDialog>
    </>
  )
}

type Props = {
  tournament: Tournament
  bracket: BracketView | null
  participantCount: number
  reload: () => Promise<void>
}

export default function OrganizerPanel({ tournament, bracket, participantCount, reload }: Props) {
  const id = tournament.tournamentId

  return (
    <section className="section organizer-panel">
      <h2>Organizer controls</h2>

      {tournament.state === 'Draft' && (
        <div className="action-row">
          <ActionButton label="Publish" onRun={async () => { await publish(id); await reload() }} />
          <CancelAction tournamentId={id} onDone={reload} />
        </div>
      )}

      {tournament.state === 'Published' && (
        <div className="action-row">
          <ActionButton label="Open registration" onRun={async () => { await openRegistration(id); await reload() }} />
          <CancelAction tournamentId={id} onDone={reload} />
        </div>
      )}

      {tournament.state === 'RegistrationOpen' && (
        <>
          <AddParticipantForm tournamentId={id} onDone={reload} />
          <div className="action-row">
            <CloseRegistrationAction tournamentId={id} participantCount={participantCount} onDone={reload} />
            <CancelAction tournamentId={id} onDone={reload} />
          </div>
        </>
      )}

      {tournament.state === 'RegistrationClosed' && (
        <div className="action-row">
          {!tournament.bracketId && (
            <ActionButton label="Generate bracket" onRun={async () => { await generateBracket(id); await reload() }} />
          )}
          <ActionButton label="Start tournament" onRun={async () => { await startTournament(id); await reload() }} />
          <CancelAction tournamentId={id} onDone={reload} />
        </div>
      )}

      {tournament.state === 'InProgress' && bracket && (
        <>
          <div className="matches-list">
            {actionableMatches(bracket.nodes).length === 0 ? (
              <p className="muted">Waiting for the next match to be ready.</p>
            ) : (
              actionableMatches(bracket.nodes).map((n) => (
                <MatchActions key={n.nodeId} node={n} onDone={reload} />
              ))
            )}
          </div>
          <div className="action-row">
            {isFinalDecided(bracket.nodes) ? (
              <ActionButton label="Complete tournament" onRun={async () => { await completeTournament(id); await reload() }} />
            ) : (
              <p className="muted">Complete becomes available once the final is decided.</p>
            )}
            <CancelAction tournamentId={id} onDone={reload} />
          </div>
        </>
      )}

      {(tournament.state === 'Paused' || tournament.state === 'Completed' || tournament.state === 'Cancelled') && (
        <p className="muted">No further actions are available.</p>
      )}
    </section>
  )
}