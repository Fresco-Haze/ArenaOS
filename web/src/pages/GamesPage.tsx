import { Link } from 'react-router'
import { useApi } from '../hooks/useApi'
import { useGames } from '../lib/useGames'
import { PublicStatsView } from '../model'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'
import { gameBannerStyle } from '../lib/gameBanners'

const filterHref = (name: string) => `/tournaments?game=${encodeURIComponent(name)}`

// Every game gets a tile. Games with public tournaments come first (the API sorts
// the counts), then the rest alphabetically with "No tournaments yet".
export default function GamesPage() {
  const stats = useApi('/stats', PublicStatsView, true)
  const allGames = useGames()
  const s = stats.data
  const counted = s ? s.byGame : []
  const others = [...allGames]
    .filter((g) => !counted.some((x) => x.game.toLowerCase() === g.toLowerCase()))
    .sort((a, b) => a.localeCompare(b))
  const tiles = [
    ...counted.map(({ game, count }) => ({ game, count })),
    ...others.map((g) => ({ game: g, count: 0 })),
  ]

  return (
    <div>
      <PageHeader title="Games" />
      {stats.error ? (
        <ErrorBanner message={stats.error} onRetry={stats.retry} />
      ) : s === null ? (
        <LoadingBlock label="Loading games" />
      ) : (
        <>
          {tiles.length === 0 ? (
            <p className="muted">No games yet.</p>
          ) : (
            <ul className="gtiles">
              {tiles.map(({ game, count }) => (
                <li key={game} className="gtile">
                  <div className="gtile-art" data-game={game} style={gameBannerStyle(game)} />
                  <div className="gtile-body">
                    <h2 className="gtile-name">{game}</h2>
                    <p className="gtile-count">
                      {count === 0 ? 'No tournaments yet' : `${count} ${count === 1 ? 'tournament' : 'tournaments'}`}
                    </p>
                    <Link to={filterHref(game)} className="gtile-cta">Explore &rarr;</Link>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </div>
  )
}