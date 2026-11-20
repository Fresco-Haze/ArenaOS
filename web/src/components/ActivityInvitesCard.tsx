import { useState } from 'react'
import { Link } from 'react-router'
import { ApiError } from '../api'
import { useApi } from '../hooks/useApi'
import { timeAgo } from '../lib/cardDate'
import { acceptTeamInvite, declineTeamInvite } from '../lib/teamActions'
import { ActivityList, MyTeamInviteList } from '../model'
import type { ActivityItem } from '../model'
import ErrorBanner from './ErrorBanner'
import LoadingBlock from './LoadingBlock'
import TeamCrest from './TeamCrest'

const EVENT_TEXT: Record<ActivityItem['event'], string> = {
  Published: 'was published',
  RegistrationOpened: 'opened registration',
  Started: 'started',
  Completed: 'finished',
  Cancelled: 'was cancelled',
  Reopened: 'was reopened',
  Other: 'was updated',
}

export default function ActivityInvitesCard() {
  const activity = useApi('/me/activity', ActivityList)
  const invites = useApi('/me/team-invites', MyTeamInviteList)
  const [now] = useState(() => Date.now())
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  async function respond(team: string, accept: boolean) {
    setBusy(team)
    setError(null)
    try {
      if (accept) await acceptTeamInvite(team)
      else await declineTeamInvite(team)
      invites.retry()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not answer the invite')
    } finally {
      setBusy(null)
    }
  }

  const pending = invites.data ? invites.data.invites : []

  return (
    <section className="pc-card" aria-labelledby="pc-act-h">
      <div className="pc-card-head">
        <h2 id="pc-act-h">Platform activity &amp; invites</h2>
        {pending.length > 0 && <span className="badge badge-neutral">{pending.length} pending</span>}
      </div>
      {error && <p role="alert" className="form-error">{error}</p>}
      {pending.length > 0 && (
        <ul className="pc-invites">
          {pending.map((i) => (
            <li key={i.team}>
              <TeamCrest name={i.team} size={32} team />
              <span className="pc-invite-text">
                <strong>{i.team}</strong>
                <span className="muted"> invited by {i.invitedBy}</span>
              </span>
              <button type="button" className="btn-primary" disabled={busy === i.team} onClick={() => void respond(i.team, true)}>
                Accept
              </button>
              <button type="button" disabled={busy === i.team} onClick={() => void respond(i.team, false)}>
                Decline
              </button>
            </li>
          ))}
        </ul>
      )}
      {activity.error ? (
        <ErrorBanner message={activity.error} onRetry={activity.retry} />
      ) : !activity.data ? (
        <LoadingBlock label="Loading activity" />
      ) : activity.data.activity.length === 0 ? (
        pending.length === 0 && <p className="muted">Activity on your tournaments and team invites appear here.</p>
      ) : (
        <ul className="pc-activity">
          {activity.data.activity.map((a, i) => (
            <li key={i}>
              <Link to={`/tournaments/${a.tournamentId}`}>{a.name}</Link> {EVENT_TEXT[a.event]}
              <span className="muted"> &middot; {timeAgo(a.at, now)}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}