import { useState } from 'react'
import { Link } from 'react-router'
import { ApiError } from '../api'
import { cancelJoinRequest, joinTournament, withdrawFromTournament } from '../lib/tournamentActions'
import type { JoinRequestStatus, Tournament } from '../model'

export default function JoinBar({
  tournament: t,
  signedIn,
  registered,
  requestStatus,
  onDone,
}: {
  tournament: Tournament
  signedIn: boolean
  registered: boolean
  requestStatus?: JoinRequestStatus | null
  onDone: () => Promise<void>
}) {
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [now] = useState(() => Date.now())

  async function run(action: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await action()
      await onDone()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  if (t.state !== 'RegistrationOpen') {
    return registered ? <p className="muted tp-join">You are registered.</p> : null
  }
  if (t.participantMode === 'SquadOnly') {
    return <p className="muted tp-join">Teams are registered by the organizer.</p>
  }

  if (registered) {
    return (
      <div className="tp-join">
        <p role="status">You&rsquo;re registered.</p>
        <button onClick={() => void run(() => withdrawFromTournament(t.tournamentId))} disabled={busy}>
          {busy ? 'Working' : 'Withdraw'}
        </button>
        {error && <p role="alert" className="form-error">{error}</p>}
      </div>
    )
  }

  if (requestStatus === 'Pending') {
    return (
      <div className="tp-join">
        <p role="status">Waiting for the organizer&rsquo;s approval.</p>
        <button onClick={() => void run(() => cancelJoinRequest(t.tournamentId))} disabled={busy}>
          {busy ? 'Working' : 'Cancel request'}
        </button>
        {error && <p role="alert" className="form-error">{error}</p>}
      </div>
    )
  }
  if (requestStatus === 'Declined') {
    return <p className="muted tp-join">The organizer declined your request to join.</p>
  }

  if (t.registrationDeadline && now > new Date(t.registrationDeadline).getTime()) {
    return <p className="muted tp-join">Registration deadline has passed.</p>
  }

  if ((t.registeredCount ?? 0) >= t.maxParticipants) {
    return <p className="muted tp-join">Registration is full.</p>
  }

  if (!signedIn) {
    const next = encodeURIComponent(`/tournaments/${t.tournamentId}`)
    return (
      <div className="tp-join">
        <Link to={`/login?next=${next}`} className="button-link btn-primary">{t.requireApproval ? 'Request to join' : 'Register Now'}</Link>
      </div>
    )
  }

  return (
    <div className="tp-join">
      <button className="btn-primary" onClick={() => void run(() => joinTournament(t.tournamentId))} disabled={busy}>
        {busy ? (t.requireApproval ? 'Requesting' : 'Registering') : (t.requireApproval ? 'Request to join' : 'Register Now')}
      </button>
      {error && <p role="alert" className="form-error">{error}</p>}
    </div>
  )
}