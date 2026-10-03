import { Link } from 'react-router'
import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import ConfirmDialog from './ConfirmDialog'
import MatchActions from './MatchActions'
import { actionableMatches, isBracketDecided } from '../lib/bracket'
import {
  publish, openRegistration, addParticipant, registerSquad, closeRegistration,
  generateBracket, startTournament, completeTournament, cancelTournament,
  setThirdPlaceMatch,
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

type ImportResult = {
  added: number
  alreadyIn: string[]
  rejected: { name: string; why: string }[]
  left: string[]
  stopped: string | null
}

// One name per line: trimmed, blanks dropped, duplicates dropped ignoring case
// (player names are case-sensitive in the backend, so "Alice" and "alice"
// would otherwise register as two different players).
function cleanNames(raw: string): string[] {
  const seen = new Set<string>()
  const out: string[] = []
  for (const line of raw.split(/\r?\n/)) {
    const name = line.trim()
    if (!name) continue
    const key = name.toLowerCase()
    if (seen.has(key)) continue
    seen.add(key)
    out.push(name)
  }
  return out
}

function AddManyPlayersForm({ tournamentId, room, onDone }: { tournamentId: number; room: number; onDone: () => Promise<void> }) {
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<ImportResult | null>(null)

  const names = cleanNames(text)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    if (names.length === 0) return
    setBusy(true)
    setResult(null)
    let added = 0
    const alreadyIn: string[] = []
    const rejected: { name: string; why: string }[] = []
    let left: string[] = []
    let stopped: string | null = null

    for (let i = 0; i < names.length; i++) {
      try {
        await addParticipant(tournamentId, names[i])
        added++
      } catch (err) {
        if (err instanceof ApiError && err.code === 'ALREADY_REGISTERED') {
          alreadyIn.push(names[i])
        } else if (err instanceof ApiError && err.code === 'VALIDATION_FAILED') {
          rejected.push({ name: names[i], why: err.message })
        } else {
          // Full, registration closed, session expired, server down:
          // more calls would only fail the same way.
          stopped = err instanceof ApiError ? err.message : 'Could not reach the server'
          left = names.slice(i)
          break
        }
      }
    }

    setResult({ added, alreadyIn, rejected, left, stopped })
    setText(left.join('\n'))
    try {
      await onDone()
    } catch {
      // the page shows its own refresh error
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="inline-form bulk-add">
      <label>
        Player names
        <textarea
          value={text}
          onChange={(e) => setText(e.target.value)}
          rows={Math.min(Math.max(text.split(/\r?\n/).length, 1), 8)}
          placeholder="Type a name, or paste a list (one per line)"
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault()
              e.currentTarget.form?.requestSubmit()
            }
          }}
        />
      </label>
      {names.length > 1 && (
        <p className="muted">
          {names.length} {names.length === 1 ? 'name' : 'names'}
          {names.length > room && ` - room for ${Math.max(room, 0)} more, the rest will stay in the box`}
        </p>
      )}
      <button type="submit" disabled={busy || names.length === 0}>
        {busy ? 'Adding' : names.length > 1 ? 'Add ' + names.length + ' players' : 'Add player'}
      </button>
      {result && (
        <div role="status">
          <p>Added {result.added}.</p>
          {result.alreadyIn.length > 0 && (
            <p className="muted">Already registered: {result.alreadyIn.join(', ')}</p>
          )}
          {result.rejected.map((r) => (
            <p key={r.name} className="form-error">{r.name}: {r.why}</p>
          ))}
          {result.stopped && (
            <p className="form-error">
              {result.stopped} {result.left.length} {result.left.length === 1 ? 'name is' : 'names are'} still in the box.
            </p>
          )}
        </div>
      )}
    </form>
  )
}
function RegisterSquadForm({ tournamentId, onDone }: { tournamentId: number; onDone: () => Promise<void> }) {
  const [teamName, setTeamName] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setError(null)
    try {
      await registerSquad(tournamentId, teamName)
      setTeamName('')
      await onDone()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="inline-form">
      <label>
        Team name
        <input value={teamName} onChange={(e) => setTeamName(e.target.value)} required />
      </label>
      <p className="muted">
        Don't have a team yet? <Link to="/teams/new">Create one</Link>.
      </p>
      {error && <p role="alert" className="form-error">{error}</p>}
      <button type="submit" disabled={busy}>{busy ? 'Registering' : 'Register team'}</button>
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

function CloseRegistrationAction({ tournamentId, participantCount, unit, onDone }:
  { tournamentId: number; participantCount: number; unit: string; onDone: () => Promise<void> }) {
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
        <p>Close registration with {participantCount} {unit}? This can't be reopened.</p>
      </ConfirmDialog>
    </>
  )
}

function ThirdPlaceToggle({ tournament, onDone }: { tournament: Tournament; onDone: () => Promise<void> }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function toggle(next: boolean) {
    setBusy(true)
    setError(null)
    try {
      await setThirdPlaceMatch(tournament.tournamentId, next)
      await onDone()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="action-item">
      <label>
        <input
          type="checkbox"
          checked={tournament.thirdPlaceMatch}
          disabled={busy}
          onChange={(e) => void toggle(e.target.checked)}
        />
        Third-place match
      </label>
      {error && <p role="alert" className="form-error">{error}</p>}
    </div>
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

      {tournament.format === 'SingleElimination' &&
       (['Draft', 'Published', 'RegistrationOpen'].includes(tournament.state) ||
          (tournament.state === 'RegistrationClosed' && !tournament.bracketId)) && (
          <ThirdPlaceToggle tournament={tournament} onDone={reload} />
       )}

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
          {tournament.participantMode === 'IndividualOnly' && <AddManyPlayersForm tournamentId={id} room={tournament.maxParticipants - participantCount} onDone={reload} />}
          {tournament.participantMode === 'SquadOnly' && <RegisterSquadForm tournamentId={id} onDone={reload} />}
          <div className="action-row">
            <CloseRegistrationAction tournamentId={id} participantCount={participantCount} unit={tournament.participantMode === 'SquadOnly' ? 'teams' : 'players'} onDone={reload} />
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
                <MatchActions key={n.nodeId} node={n} format={tournament.format} onDone={reload} />
              ))
            )}
          </div>
          <div className="action-row">
            {isBracketDecided(bracket) ? (
              <ActionButton label="Complete tournament" onRun={async () => { await completeTournament(id); await reload() }} />
            ) : (
              <p className="muted">
                {bracket.thirdPlaceNodeId !== null
                  ? 'Complete becomes available once the final and the third-place match are decided.'
                  : 'Complete becomes available once the final is decided.'}
              </p>
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