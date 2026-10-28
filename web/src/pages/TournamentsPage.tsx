import { useState } from 'react'
import { Link, useSearchParams } from 'react-router'
import { api, ApiError } from '../api'
import { useApi } from '../hooks/useApi'
import { Game, TournamentList, gameLabel } from '../model'
import type { Tournament } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'
import TournamentCard from '../components/TournamentCard'

function query(q: string, game: string, offset = 0): string {
  const p = new URLSearchParams()
  if (q) p.set('q', q)
  if (game) p.set('game', game)
  if (offset > 0) p.set('offset', String(offset))
  return p.toString()
}

export default function TournamentsPage() {
  const [params] = useSearchParams()
  const q = (params.get('q') ?? '').trim()
  const parsed = Game.safeParse(params.get('game'))
  const game = parsed.success ? parsed.data : ''
  const qs = query(q, game)
  const href = (g: string) => {
    const s = query(q, g)
    return s ? `/tournaments?${s}` : '/tournaments'
  }

  return (
    <>
      <PageHeader title="Tournaments" />
      <nav className="chips" aria-label="Filter by game">
        <Link to={href('')} className="chip" aria-current={game === '' ? 'true' : undefined}>
          All games
        </Link>
        {Game.options.map((g) => (
          <Link key={g} to={href(g)} className="chip" aria-current={game === g ? 'true' : undefined}>
            {gameLabel[g]}
          </Link>
        ))}
      </nav>
      {/* key = the filters, so changing them starts again from page one */}
      <Results key={qs} q={q} game={game} gameName={game ? gameLabel[game] : null} qs={qs} />
    </>
  )
}

function Results({ q, game, gameName, qs }: { q: string; game: string; gameName: string | null; qs: string }) {
  const list = useApi(qs ? `/tournaments?${qs}` : '/tournaments', TournamentList, true)
  const [more, setMore] = useState<Tournament[]>([])
  const [loadingMore, setLoadingMore] = useState(false)
  const [moreError, setMoreError] = useState<string | null>(null)

  const first = list.data ? list.data.tournaments : null
  const items = first ? [...first, ...more] : null
  const total = list.data?.total ?? null
  const filtered = q !== '' || game !== ''
  const count = items ? (total ?? items.length) : 0

  async function loadMore() {
    if (!items) return
    setLoadingMore(true)
    setMoreError(null)
    try {
      const next = await api(`/tournaments?${query(q, game, items.length)}`, TournamentList, { retryAnonymously: true })
      setMore((prev) => {
        const seen = new Set([...(first ?? []), ...prev].map((t) => t.tournamentId))
        return [...prev, ...next.tournaments.filter((t) => !seen.has(t.tournamentId))]
      })
    } catch (e) {
      setMoreError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setLoadingMore(false)
    }
  }

  return (
    <>
      {filtered && items && (
        <p className="muted">
          {count} {count === 1 ? 'result' : 'results'}
          {q && <> for &ldquo;{q}&rdquo;</>}
          {gameName && <> in {gameName}</>}
        </p>
      )}
      {list.error ? (
        <ErrorBanner message={list.error} onRetry={list.retry} />
      ) : items === null ? (
        <LoadingBlock label="Loading tournaments" />
      ) : items.length === 0 ? (
        filtered ? (
          <EmptyState
            title="No tournaments match"
            action={<Link to="/tournaments" className="button-link">Clear filters</Link>}
          >
            Try a different name or game.
          </EmptyState>
        ) : (
          <EmptyState title="No public tournaments yet">
            Tournaments show up here once an organizer publishes one.
          </EmptyState>
        )
      ) : (
        <>
          <ul className="tcards">
            {items.map((t) => (
              <TournamentCard key={t.tournamentId} tournament={t} showOrganizer />
            ))}
          </ul>
          {total !== null && items.length < total && (
            <div className="load-more">
              <p className="muted">Showing {items.length} of {total}</p>
              <button type="button" onClick={() => void loadMore()} disabled={loadingMore}>
                {loadingMore ? 'Loading' : 'Load more'}
              </button>
              {moreError && <p role="alert" className="form-error">{moreError}</p>}
            </div>
          )}
        </>
      )}
    </>
  )
}