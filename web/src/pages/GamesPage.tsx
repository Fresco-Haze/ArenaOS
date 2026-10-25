import { Link } from 'react-router'
import { useApi } from '../hooks/useApi'
import { gameLabel, PublicStatsView } from '../model'
import type { Game } from '../model'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'

// "Other" is a catch-all tag, not a game, so it is not listed here.
const GAMES: readonly Game[] = ['eFootball', 'PubgMobile', 'CallOfDuty']

export default function GamesPage() {
  const stats = useApi('/stats', PublicStatsView, true)
  const s = stats.data

  return (
    <div>
      <PageHeader title="Games" />
      {stats.error ? (
        <ErrorBanner message={stats.error} onRetry={stats.retry} />
      ) : s === null ? (
        <LoadingBlock label="Loading games" />
      ) : (
        <ul className="gtiles">
          {GAMES.map((g) => {
            const n = s.byGame.find((x) => x.game === g)?.count ?? 0
            return (
              <li key={g} className="gtile">
                <div className="gtile-art" data-game={g} />
                <div className="gtile-body">
                  <h2 className="gtile-name">{gameLabel[g]}</h2>
                  <p className="gtile-count">{n} {n === 1 ? 'tournament' : 'tournaments'}</p>
                  <Link to={`/tournaments?game=${g}`} className="gtile-cta">Explore &rarr;</Link>
                </div>
              </li>
            )
          })}
          <li className="gtile gtile-soon">
            <div className="gtile-body">
              <h2 className="gtile-name">More games</h2>
              <p className="gtile-count">Coming soon</p>
            </div>
          </li>
        </ul>
      )}
    </div>
  )
}