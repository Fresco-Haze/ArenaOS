import { useEffect, useState } from 'react'
import { Link } from 'react-router'
import { api, ApiError } from '../api'
import { TournamentList } from '../model'
import type { Tournament } from '../model'

import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'
import TournamentCard from '../components/TournamentCard'

export default function MyTournamentsPage() {
  const [items, setItems] = useState<Tournament[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    let cancelled = false
    api('/me/tournaments', TournamentList)
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

  const createLink = (label: string) => (
    <Link to="/me/new" className="button-link btn-primary">
      {label}
    </Link>
  )

  return (
    <>
      <PageHeader
        title="My tournaments"
        actions={items !== null && items.length === 0 ? undefined : createLink('Create tournament')}
      />
      {error ? (
        <ErrorBanner message={error} onRetry={retry} />
      ) : items === null ? (
        <LoadingBlock label="Loading tournaments" />
      ) : items.length === 0 ? (
        <EmptyState title="No tournaments yet" action={createLink('Create your first tournament')}>
          Tournaments you create appear here.
        </EmptyState>
      ) : (
        <ul className="cards">
          {items.map((t) => (
            <TournamentCard key={t.tournamentId} tournament={t} />
          ))}
        </ul>
      )}
    </>
  )
}