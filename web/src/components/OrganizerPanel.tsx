import { Link } from 'react-router'
import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import ConfirmDialog from './ConfirmDialog'
import { statusClass } from '../badges'
import MatchActions from './MatchActions'
import DetailsFields from './DetailsFields'
import { deadlineError, detailsChanged, detailsFromTournament, feeError, prizeError, toPayload } from '../lib/details'
import type { DetailsValues } from '../lib/details'
import { actionableMatches, isBracketDecided } from '../lib/bracket'
import {
  publish, openRegistration, addParticipant, registerSquad, closeRegistration,
  generateBracket, startTournament, completeTournament, cancelTournament,
  setThirdPlaceMatch, listTeams, updateName, updateVisibility, updateMaxParticipants,
  pauseTournament, resumeTournament, reopenTournament, updateDetails, updateFormat,
  setRequireApproval, listJoinRequests, approveJoinRequest, declineJoinRequest,
} from '../lib/tournamentActions'
import { formatLabel, stateLabel } from '../model'
import type { BracketView, JoinRequestRow, Team, Tournament, TournamentFormat } from '../model'

function ActionButton({ label, busyLabel, onRun, primary }: { label: string; busyLabel?: string; primary?: boolean; onRun: () => Promise<void> }) {
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
      <button className={primary ? 'btn-primary' : undefined} onClick={handle} disabled={busy}>{busy ? (busyLabel ?? 'Working') : label}</button>
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

function AddManyPlayersForm({ tournamentId, room, kind = 'player', registered = [], onDone }: { tournamentId: number; room: number; kind?: 'player' | 'team'; registered?: string[]; onDone: () => Promise<void> }) {
  const squads = kind === 'team'
  const noun = squads ? 'team' : 'player'
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [result, setResult] = useState<ImportResult | null>(null)

  const names = cleanNames(text)
  const [teams, setTeams] = useState<Team[] | null>(null)
  const [pickError, setPickError] = useState<string | null>(null)
  const available = (teams ?? []).filter(
    (t) => !registered.some((r) => r.toLowerCase() === t.name.toLowerCase()),
  )

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
        await (squads ? registerSquad : addParticipant)(tournamentId, names[i])
        added++
      } catch (err) {
        if (err instanceof ApiError && err.code === 'ALREADY_REGISTERED') {
          alreadyIn.push(names[i])
        } else if (err instanceof ApiError && (err.code === 'VALIDATION_FAILED' || (squads && err.code === 'NOT_FOUND'))) {
          rejected.push({
            name: names[i],
            why: squads && err.code === 'NOT_FOUND' ? 'No team with that name. Create it first.' : err.message,
          })
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
        {squads ? 'Team names' : 'Player names'}
        <textarea
          value={text}
          onChange={(e) => setText(e.target.value)}
          rows={Math.min(Math.max(text.split(/\r?\n/).length, 1), 8)}
          placeholder={squads ? 'Type a team name, or paste a list (one per line)' : 'Type a name, or paste a list (one per line)'}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault()
              e.currentTarget.form?.requestSubmit()
            }
          }}
        />
      </label>
      {squads && (
        <details
          onToggle={(e) => {
            if (e.currentTarget.open && teams === null) {
              listTeams()
                .then((d) => setTeams(d.teams))
                .catch((err: unknown) =>
                  setPickError(err instanceof ApiError ? err.message : 'Could not reach the server'),
                )
            }
          }}
        >
          <summary>Pick from existing teams</summary>
          {pickError && <p role="alert" className="form-error">{pickError}</p>}
          {teams === null && !pickError && <p className="muted">Loading teams</p>}
          {teams !== null && teams.length === 0 && <p className="muted">No teams exist yet.</p>}
          {teams !== null && teams.length > 0 && available.length === 0 && (
            <p className="muted">All existing teams are already registered.</p>
          )}
          {available.length > 0 && (
            <div className="match-actions-buttons">
              {available.map((t) => {
                const inBox = names.some((n) => n.toLowerCase() === t.name.toLowerCase())
                return (
                  <button
                    key={t.name}
                    type="button"
                    disabled={inBox}
                    onClick={() =>
                      setText((prev) => (prev.trim() === '' ? t.name : prev.replace(/\s+$/, '') + '\n' + t.name))
                    }
                  >
                    {t.name}
                  </button>
                )
              })}
            </div>
          )}
        </details>
      )}
      {names.length > 1 && (
        <p className="muted">
          {names.length} {names.length === 1 ? 'name' : 'names'}
          {names.length > room && ` - room for ${Math.max(room, 0)} more, the rest will stay in the box`}
        </p>
      )}
      <button type="submit" disabled={busy || names.length === 0}>
        {busy ? 'Adding' : names.length > 1 ? `Add ${names.length} ${noun}s` : `Add ${noun}`}
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
function ReopenAction({ tournamentId, onDone }: { tournamentId: number; onDone: () => Promise<void> }) {
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState('')

  return (
    <>
      <button onClick={() => setOpen(true)}>Reopen tournament</button>
      <ConfirmDialog
        open={open}
        title="Reopen tournament"
        confirmLabel="Reopen tournament"
        confirmDisabled={reason.trim() === ''}
        onConfirm={async () => {
          await reopenTournament(tournamentId, reason.trim())
          setReason('')
          await onDone()
        }}
        onClose={() => setOpen(false)}
      >
        <p>
          Reopening puts the tournament back in progress so results can be corrected. The reason is kept in
          its history.
        </p>
        <label>
          Reason
          <textarea value={reason} onChange={(e) => setReason(e.target.value)} required />
        </label>
      </ConfirmDialog>
    </>
  )
}

function CancelAction({ tournamentId, onDone }: { tournamentId: number; onDone: () => Promise<void> }) {
  const [open, setOpen] = useState(false)
  const [reason, setReason] = useState('')

  return (
    <>
      <button className="btn-danger" onClick={() => setOpen(true)}>Cancel tournament</button>
      <ConfirmDialog
        open={open}
        title="Cancel tournament"
        confirmLabel="Cancel tournament" danger
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
      <button className="btn-primary" onClick={() => setOpen(true)}>Close registration</button>
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

function describeFormatChange(from: TournamentFormat, to: TournamentFormat, thirdPlace: boolean): string {
  const base = `Format: ${formatLabel[from]} \u2192 ${formatLabel[to]}.`
  if (from === 'SingleElimination' && to !== 'SingleElimination' && thirdPlace) {
    return base + ' The third-place match will be turned off.'
  }
  if (from !== 'SingleElimination' && to === 'SingleElimination') {
    return base + ' A third-place match will be added.'
  }
  return base
}

function EditDetails({ tournament, registeredCount, onDone }: {
  tournament: Tournament
  registeredCount: number
  onDone: () => Promise<void>
}) {
  const canEditMax = ['Draft', 'Published', 'RegistrationOpen'].includes(tournament.state)
  const [name, setName] = useState(tournament.name)
  const [visibility, setVisibility] = useState<'Public' | 'Private'>(tournament.visibility)
  const [max, setMax] = useState(String(tournament.maxParticipants))
  const [details, setDetails] = useState<DetailsValues>(() => detailsFromTournament(tournament))
  const [busy, setBusy] = useState(false)
  const [problems, setProblems] = useState<string[]>([])
  const [saved, setSaved] = useState(false)
  const [format, setFormat] = useState<TournamentFormat>(tournament.format)
  const formatLocked = tournament.bracketId != null
  const formatChanged = !formatLocked && format !== tournament.format
  const formatNote = formatChanged
    ? describeFormatChange(tournament.format, format, tournament.thirdPlaceMatch)
    : null

  const changed =
    name.trim() !== tournament.name ||
    visibility !== tournament.visibility ||
    (canEditMax && Number(max) !== tournament.maxParticipants) ||
    formatChanged ||
    detailsChanged(details, tournament)

  async function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setBusy(true)
    setProblems([])
    setSaved(false)
    const found: string[] = []
    async function attempt(label: string, run: () => Promise<void>) {
      try {
        await run()
      } catch (err) {
        found.push(`${label}: ${err instanceof ApiError ? err.message : 'Could not reach the server'}`)
      }
    }
    if (name.trim() !== tournament.name) {
      await attempt('Name', () => updateName(tournament.tournamentId, name.trim()))
    }
    if (visibility !== tournament.visibility) {
      await attempt('Visibility', () => updateVisibility(tournament.tournamentId, visibility))
    }
    if (canEditMax && Number(max) !== tournament.maxParticipants) {
      if (!Number.isInteger(Number(max))) found.push('Maximum: enter a whole number')
      else await attempt('Maximum', () => updateMaxParticipants(tournament.tournamentId, Number(max)))
    }
    if (formatChanged) {
      const from = tournament.format
      await attempt('Format', async () => {
        const toSingle = format === 'SingleElimination'
        // The backend rejects third-place on a non-single format, so turn it off first...
        if (from === 'SingleElimination' && !toSingle && tournament.thirdPlaceMatch) {
          await setThirdPlaceMatch(tournament.tournamentId, false)
        }
        await updateFormat(tournament.tournamentId, format)
        // ...and back on after returning to single elimination.
        if (from !== 'SingleElimination' && toSingle) {
          await setThirdPlaceMatch(tournament.tournamentId, true)
        }
      })
    }
    if (detailsChanged(details, tournament)) {
      await attempt('Details', () => updateDetails(tournament.tournamentId, toPayload(details, tournament)))
    }
    setProblems(found)
    setSaved(found.length === 0)
    try {
      await onDone()
    } catch {
      // the page shows its own refresh error
    } finally {
      setBusy(false)
    }
  }

  return (
    <details className="edit-details">
      <summary>Edit details</summary>
      <form onSubmit={handleSubmit} className="inline-form bulk-add">
        <label>
          Name
          <input value={name} onChange={(e) => setName(e.target.value)} />
        </label>
        <label>
          Visibility
          <select value={visibility} onChange={(e) => setVisibility(e.target.value as 'Public' | 'Private')}>
            <option value="Public">Public</option>
            <option value="Private">Private</option>
          </select>
        </label>
        <DetailsFields
          values={details}
          onChange={setDetails}
          afterGame={
            <>
              <label>
                Format
                <select
                  value={format}
                  disabled={formatLocked}
                  onChange={(e) => setFormat(e.target.value as TournamentFormat)}
                >
                  <option value="SingleElimination">Single elimination</option>
                  <option value="DoubleElimination">Double elimination</option>
                  <option value="RoundRobin">Round robin</option>
                </select>
              </label>
              {formatLocked && <p className="muted">The format can't change once the bracket exists.</p>}
              {formatNote && <p role="status" className="muted">{formatNote}</p>}
            </>
          }
        />
        {canEditMax && (
          <>
            <label>
              Maximum {tournament.participantMode === 'SquadOnly' ? 'teams' : 'players'}
              <input type="number" min={2} value={max} onChange={(e) => setMax(e.target.value)} />
            </label>
            <p className="muted">Can't go below the {registeredCount} already registered.</p>
          </>
        )}
        <div className="edit-status">
          <span>Status</span>
          <span className={'badge ' + statusClass[tournament.state]}>{stateLabel[tournament.state]}</span>
        </div>
        <p className="muted">
          Change the status with the buttons below.
        </p>
        {problems.map((p) => (
          <p key={p} role="alert" className="form-error">{p}</p>
        ))}
        {saved && <p role="status">Saved.</p>}
        <button type="submit" className="btn-primary" disabled={busy || !changed || prizeError(details.prize) !== null || deadlineError(details) !== null || feeError(details.entryFee) !== null}>{busy ? 'Saving' : 'Save changes'}</button>
      </form>
    </details>
  )
}

function ApprovalToggle({ tournament, onDone }: { tournament: Tournament; onDone: () => Promise<void> }) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function toggle(next: boolean) {
    setBusy(true)
    setError(null)
    try {
      await setRequireApproval(tournament.tournamentId, next)
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
          checked={tournament.requireApproval}
          disabled={busy}
          onChange={(e) => void toggle(e.target.checked)}
        />
        Approve each join request
      </label>
      {error && <p role="alert" className="form-error">{error}</p>}
    </div>
  )
}

function RequestsSection({ tournament, refreshKey, onDone }: { tournament: Tournament; refreshKey: string; onDone: () => Promise<void> }) {
  const id = tournament.tournamentId
  const [rows, setRows] = useState<JoinRequestRow[]>([])
  const [error, setError] = useState<string | null>(null)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    let alive = true
    listJoinRequests(id)
      .then((r) => {
        if (alive) {
          setRows(r.requests)
          setError(null)
        }
      })
      .catch((e) => {
        if (alive) setError(e instanceof ApiError ? e.message : 'Could not reach the server')
      })
    return () => {
      alive = false
    }
  }, [id, refreshKey, tick])

  const open = rows.filter((r) => r.status !== 'Approved')
  async function after() {
    await onDone()
    setTick((n) => n + 1)
  }

  if (!tournament.requireApproval && open.length === 0) return null

  return (
    <div className="requests">
      <h3>Join requests</h3>
      {error && <p role="alert" className="form-error">{error}</p>}
      {open.length === 0 ? (
        <p className="muted">No requests waiting.</p>
      ) : (
        <ul className="req-list">
          {open.map((r) => (
            <li key={r.userId} className="req-row">
              <span className="req-name">{r.username}</span>
              <span className="muted">{r.status === 'Pending' ? 'wants to join' : 'declined'}</span>
              <span className="req-actions">
                <ActionButton
                  primary
                  label={r.status === 'Pending' ? 'Approve' : 'Approve anyway'}
                  onRun={async () => { await approveJoinRequest(id, r.userId); await after() }}
                />
                {r.status === 'Pending' && (
                  <ActionButton
                    label="Decline"
                    onRun={async () => { await declineJoinRequest(id, r.userId); await after() }}
                  />
                )}
              </span>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

type Props = {
  tournament: Tournament
  bracket: BracketView | null
  participantCount: number
  registered: string[]
  refreshKey: string
  reload: () => Promise<void>
}

export default function OrganizerPanel({ tournament, bracket, participantCount, registered, refreshKey, reload }: Props) {
  const id = tournament.tournamentId

  return (
    <section className="section organizer-panel">
      <h2>Organizer controls</h2>

      {tournament.participantMode === 'IndividualOnly' &&
       ['Draft', 'Published', 'RegistrationOpen', 'RegistrationClosed'].includes(tournament.state) && (
        <ApprovalToggle tournament={tournament} onDone={reload} />
      )}

      {tournament.format === 'SingleElimination' && !tournament.thirdPlaceMatch &&
       (['Draft', 'Published', 'RegistrationOpen'].includes(tournament.state) ||
          (tournament.state === 'RegistrationClosed' && !tournament.bracketId)) && (
          <ThirdPlaceToggle tournament={tournament} onDone={reload} />
       )}

      {['Draft', 'Published', 'RegistrationOpen', 'RegistrationClosed'].includes(tournament.state) && (
        <EditDetails tournament={tournament} registeredCount={participantCount} onDone={reload} />
      )}

      {tournament.state === 'Draft' && (
        <div className="action-row">
          <ActionButton primary label="Publish" onRun={async () => { await publish(id); await reload() }} />
        </div>
      )}

      {tournament.state === 'Published' && (
        <div className="action-row">
          <ActionButton primary label="Open registration" onRun={async () => { await openRegistration(id); await reload() }} />
        </div>
      )}

      {tournament.state === 'RegistrationOpen' && (
        <>
          {tournament.participantMode === 'IndividualOnly' && (
            <RequestsSection tournament={tournament} refreshKey={refreshKey} onDone={reload} />
          )}
          {tournament.participantMode === 'IndividualOnly' && <AddManyPlayersForm tournamentId={id} room={tournament.maxParticipants - participantCount} onDone={reload} />}
          {tournament.participantMode === 'SquadOnly' && (
            <>
              <AddManyPlayersForm tournamentId={id} room={tournament.maxParticipants - participantCount} kind="team" registered={registered} onDone={reload} />
              <p className="muted">
                Don't have a team yet? <Link to="/teams/new">Create one</Link>.
              </p>
            </>
          )}
          <div className="action-row">
            <CloseRegistrationAction tournamentId={id} participantCount={participantCount} unit={tournament.participantMode === 'SquadOnly' ? 'teams' : 'players'} onDone={reload} />
          </div>
        </>
      )}

      {tournament.state === 'RegistrationClosed' && (
        <div className="action-row">
          {!tournament.bracketId && (
            <ActionButton primary label="Generate bracket" onRun={async () => { await generateBracket(id); await reload() }} />
          )}
          <ActionButton primary={!!tournament.bracketId} label="Start tournament" onRun={async () => { await startTournament(id); await reload() }} />
        </div>
      )}

      {tournament.state === 'InProgress' && bracket && (
        <>
          <div className="matches-list">
            {actionableMatches(bracket.nodes).length === 0 ? (
              <p className="muted">{isBracketDecided(bracket) ? 'All matches are decided.' : 'Waiting for the next match to be ready.'}</p>
            ) : (
              actionableMatches(bracket.nodes).map((n) => (
                <MatchActions key={n.nodeId} node={n} format={tournament.format} onDone={reload} />
              ))
            )}
          </div>
          {tournament.format !== 'RoundRobin' && (() => {
            const done = bracket.nodes
              .filter((n) => n.match?.status === 'Completed')
              .sort((a, b) => a.round - b.round || a.nodeId - b.nodeId)
            return done.length === 0 ? null : (
              <details className="completed-matches">
                <summary>Completed matches ({done.length}) - correct a result</summary>
                <div className="matches-list">
                  {done.map((n) => (
                    <MatchActions key={n.nodeId} node={n} format={tournament.format} onDone={reload} />
                  ))}
                </div>
              </details>
            )
          })()}
          <div className="action-row">
            {isBracketDecided(bracket) ? (
              <ActionButton primary label="Complete tournament" onRun={async () => { await completeTournament(id); await reload() }} />
            ) : (
              <p className="muted">
                {bracket.thirdPlaceNodeId !== null
                  ? 'Complete becomes available once the final and the third-place match are decided.'
                  : tournament.format === 'RoundRobin'
                    ? 'Complete becomes available once every match is decided.'
                    : 'Complete becomes available once the final is decided.'}
              </p>
            )}
            <ActionButton label="Pause tournament" onRun={async () => { await pauseTournament(id); await reload() }} />
          </div>
        </>
      )}

      {tournament.state === 'Paused' && (
        <>
          <p className="muted">The tournament is paused. Results can't be recorded until you resume it.</p>
          <div className="action-row">
            <ActionButton primary label="Resume tournament" onRun={async () => { await resumeTournament(id); await reload() }} />
          </div>
        </>
      )}

      {tournament.state === 'Completed' && (
        <div className="action-row">
          <ReopenAction tournamentId={id} onDone={reload} />
        </div>
      )}

      {tournament.state === 'Cancelled' && (
        <p className="muted">No further actions are available.</p>
      )}
      {!['Completed', 'Cancelled'].includes(tournament.state) && (
        <div className="danger-zone">
          <CancelAction tournamentId={id} onDone={reload} />
        </div>
      )}    </section>
  )
}