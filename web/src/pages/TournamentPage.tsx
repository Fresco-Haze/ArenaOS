import { Link } from 'react-router'

import { useAuth } from '../auth/context'
import { useTournament } from '../hooks/useTournament'

import { participantName } from '../lib/participants'
import { formatLabel, stateLabel } from '../model'

import Bracket from '../components/Bracket'
import OrganizerPanel from '../components/OrganizerPanel'

export default function TournamentPage({ id }: { id: string }) {
  const { user } = useAuth()
  const { state, reload } = useTournament(id)

  if (state.kind === 'loading') {
    return <p role="status" className="muted">Loading tournament</p>
  }

  if (state.kind === 'notfound') {
    return (
      <>
        <h1>Tournament not found</h1>
        <p className="muted">
          It may not exist, or it may be private.
        </p>

        {!user && (
          <p>
            <Link to={`/login?next=/tournaments/${id}`}>
              Sign in
            </Link>{' '}
            to check.
          </p>
        )}

        <p>
          <Link to="/">Back to public tournaments</Link>
        </p>
      </>
    )
  }

  if (state.kind === 'error') {
    return (
      <>
        <h1>Tournament</h1>
        <p role="alert">{state.message}</p>
        <button onClick={() => void reload()}>
          Try again
        </button>
      </>
    )
  }

  const { view, bracket, lastUpdated } = state.data
  const t = view.tournament

  return (
    <>
      <h1>{t.name}</h1>

      <p className="meta">
        {stateLabel[t.state]} · {formatLabel[t.format]} · up to{' '}
        {t.maxParticipants} players
      </p>

      <p className="meta">
        Organized by {t.organizer}
      </p>

      <section className="section">
        <h2>
          Players ({view.participants.length} of {t.maxParticipants})
        </h2>

        {view.participants.length === 0 ? (
          <p className="muted">
            No players have registered yet.
          </p>
        ) : (
          <ul className="plain-list">
            {view.participants.map((p, i) => (
              <li key={i}>{participantName(p)}</li>
            ))}
          </ul>
        )}
      </section>

      <section className="section">
        <h2>Bracket</h2>

        {bracket ? (
          <Bracket bracket={bracket} />
        ) : (
          <p className="muted">
            The bracket has not been generated yet.
          </p>
        )}
      </section>

      {view.viewerIsOwner && (
        <OrganizerPanel
          tournament={t}
          bracket={bracket}
          participantCount={view.participants.length}
          reload={reload}
        />
      )}

      <p className="toolbar muted">
        <span>
          Updated at {new Date(lastUpdated).toLocaleTimeString()}
        </span>

        <button onClick={() => void reload()} disabled={state.refreshing}>
          {state.refreshing ? 'Refreshing' : 'Refresh'}
        </button>
      </p>

      {state.refreshFailed && (
        <p role="status" className="muted">
          Couldn't refresh, retrying.
        </p>
      )}
    </>
  )
}