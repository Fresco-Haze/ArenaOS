import { Link, useSearchParams } from 'react-router'
import { useApi } from '../hooks/useApi'
import { Game, TournamentList, gameLabel } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'
import TournamentCard from '../components/TournamentCard'

const SERVER_CAP = 50

function query(q: string, game: string): string {
  const p = new URLSearchParams()
  if (q) p.set('q', q)
  if (game) p.set('game', game)
  return p.toString()
}

export default function TournamentsPage() {
  const [params] = useSearchParams()
  const q = (params.get('q') ?? '').trim()
  const parsed = Game.safeParse(params.get('game'))
  const game = parsed.success ? parsed.data : ''
  const qs = query(q, game)
  const list = useApi(qs ? `/tournaments?${qs}` : '/tournaments', TournamentList, true)
  const items = list.data ? list.data.tournaments : null
  const filtered = q !== '' || game !== ''
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
      {filtered && items && (
        <p className="muted">
          {items.length} {items.length === 1 ? 'result' : 'results'}
          {q && <> for &ldquo;{q}&rdquo;</>}
          {game && <> in {gameLabel[game]}</>}
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
          {items.length >= SERVER_CAP && (
            <p className="muted">Showing the newest {SERVER_CAP}. Search or pick a game to narrow it down.</p>
          )}
        </>
      )}
    </>
  )
}