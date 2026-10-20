import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router'
import { api, ApiError } from '../api'
import { TournamentList } from '../model'
import type { Tournament } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'
import TournamentCard from '../components/TournamentCard'

export default function TournamentsPage() {
  const [params] = useSearchParams()
  const q = (params.get('q') ?? '').trim()
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

  const shown = items && q ? items.filter((t) => t.name.toLowerCase().includes(q.toLowerCase())) : items

  return (
    <>
      <PageHeader title="Tournaments" />
      {q && shown && (
        <p className="muted">
          {shown.length} {shown.length === 1 ? 'result' : 'results'} for &ldquo;{q}&rdquo;
        </p>
      )}
      {error ? (
        <ErrorBanner message={error} onRetry={retry} />
      ) : shown === null ? (
        <LoadingBlock label="Loading tournaments" />
      ) : shown.length === 0 ? (
        q ? (
          <EmptyState
            title="No tournaments match your search"
            action={<Link to="/tournaments" className="button-link">Clear search</Link>}
          >
            Try a different name.
          </EmptyState>
        ) : (
          <EmptyState title="No public tournaments yet">
            Tournaments show up here once an organizer publishes one.
          </EmptyState>
        )
      ) : (
        <ul className="tcards">
          {shown.map((t) => (
            <TournamentCard key={t.tournamentId} tournament={t} showOrganizer />
          ))}
        </ul>
      )}
    </>
  )
}