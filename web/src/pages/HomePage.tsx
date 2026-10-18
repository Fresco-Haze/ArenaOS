import TournamentCard from '../components/TournamentCard'
import { useEffect, useState } from 'react'
import { api, ApiError } from '../api'
import { TournamentList, } from '../model'
import type { Tournament } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'

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
        <ErrorBanner message={error} onRetry={retry} />
      ) : items === null ? (
        <LoadingBlock label="Loading tournaments" />
      ) : items.length === 0 ? (
        <EmptyState title="No public tournaments yet">Tournaments show up here once an organizer publishes one.</EmptyState>
      ) : (
        <ul className="cards">
          {items.map((t) => (
            <TournamentCard key={t.tournamentId} tournament={t} showOrganizer />
          ))}
        </ul>
      )}
    </>
  )
}