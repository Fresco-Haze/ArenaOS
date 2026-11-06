import { Link } from 'react-router'
import { useApi } from '../hooks/useApi'
import { useGames } from '../lib/useGames'
import { PublicStatsView } from '../model'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'

const filterHref = (name: string) => `/tournaments?game=${encodeURIComponent(name)}`

// Every game that has public tournaments gets a tile, most active first (the API
// already sorts the counts). The rest of the list is below, as plain links.
export default function GamesPage() {
  const stats = useApi('/stats', PublicStatsView, true)
  const allGames = useGames()
  const s = stats.data

  return (
    <div>
      <PageHeader title="Games" />
      {stats.error ? (
        <ErrorBanner message={stats.error} onRetry={stats.retry} />
      ) : s === null ? (
        <LoadingBlock label="Loading games" />
      ) : (
        <>
          {s.byGame.length === 0 ? (
            <p className="muted">No public tournaments have a game yet.</p>
          ) : (
            <ul className="gtiles">
              {s.byGame.map(({ game, count }) => (
                <li key={game} className="gtile">
                  <div className="gtile-art" data-game={game} />
                  <div className="gtile-body">
                    <h2 className="gtile-name">{game}</h2>
                    <p className="gtile-count">{count} {count === 1 ? 'tournament' : 'tournaments'}</p>
                    <Link to={filterHref(game)} className="gtile-cta">Explore &rarr;</Link>
                  </div>
                </li>
              ))}
            </ul>
          )}
          {allGames.length > 0 && (
            <>
              <h2 className="panel-title">All games</h2>
              <ul className="games-all">
                {allGames
                  .filter((g) => !s.byGame.some((x) => x.game.toLowerCase() === g.toLowerCase()))
                  .map((g) => (
                    <li key={g}>
                      <Link to={filterHref(g)}>{g}</Link>
                    </li>
                  ))}
              </ul>
            </>
          )}
        </>
      )}
    </div>
  )
}