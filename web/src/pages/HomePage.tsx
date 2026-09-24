import { useEffect, useState } from 'react'
import { Link } from 'react-router'
import { api, ApiError } from '../api'
import { TournamentList, formatLabel, stateLabel } from '../model'
import type { Tournament } from '../model'

export default function HomePage() {
  const [items, setItems] = useState<Tournament[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    let cancelled = false
    api('/tournaments', TournamentList, { retryAnonymously: true })
      .then((d) => {
        if (!cancelled) setItems(d.tournaments)
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setError(e instanceof ApiError ? e.message : 'Could not reach the server')
        }
      })
    return () => {
      cancelled = true
    }
  }, [attempt])

  function retry() {
    setError(null)
    setItems(null)
    setAttempt((n) => n + 1)
  }

  return (
    <>
      <h1>Public tournaments</h1>
      {error ? (
        <>
          <p role="alert">{error}</p>
          <button onClick={retry}>Try again</button>
        </>
      ) : items === null ? (
        <p role="status" className="muted">Loading tournaments</p>
      ) : items.length === 0 ? (
        <p className="muted">No public tournaments yet.</p>
      ) : (
        <ul className="cards">
          {items.map((t) => (
            <li key={t.tournamentId} className="card">
              <h2>
                <Link to={`/tournaments/${t.tournamentId}`}>{t.name}</Link>
              </h2>
              <p className="meta">
                {stateLabel[t.state]} · {formatLabel[t.format]} · up to {t.maxParticipants} players
              </p>
              <p className="meta">Organized by {t.organizer}</p>
            </li>
          ))}
        </ul>
      )}
    </>
  )
}