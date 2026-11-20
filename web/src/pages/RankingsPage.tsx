import GameFilter from '../components/GameFilter'
import { Link, useSearchParams } from 'react-router'
import { useApi } from '../hooks/useApi'
import { Game, RankingList, gameLabel } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'

// Wins as a share of matches played, whole percent. No matches played: a dash.
function winRate(wins: number, played: number): string {
  return played > 0 ? Math.min(100, Math.round((wins / played) * 100)) + '%' : '\u2014'
}

export default function RankingsPage() {
  const [params] = useSearchParams()
  const parsed = Game.safeParse(params.get('game'))
  const game = parsed.success ? parsed.data : ''
  const list = useApi(game ? `/rankings?limit=50&game=${encodeURIComponent(game)}` : '/rankings?limit=50', RankingList, true)
  const rows = list.data ? list.data.rankings : null
  const href = (g: string) => (g ? `/rankings?game=${encodeURIComponent(g)}` : '/rankings')

  return (
    <>
      <PageHeader title="Rankings" />
      <div className="filter-panel">
        <GameFilter current={game} href={href} />
      </div>
      <p className="muted">
        Ranked by titles won, then match wins. Only public tournaments count. Players with the same record share a rank. Win rate is wins out of matches played and does not affect the order.
      </p>
      {list.error ? (
        <ErrorBanner message={list.error} onRetry={list.retry} />
      ) : rows === null ? (
        <LoadingBlock label="Loading rankings" />
      ) : rows.length === 0 ? (
        <EmptyState title="No rankings yet">
          {game ? `No matches have been played in ${gameLabel[game]} yet.` : 'Rankings appear once matches have been played.'}
        </EmptyState>
      ) : (
        <>
        <ol className="podium">
          {rows.slice(0, 3).map((r) => (
            <li key={r.player} className={'podium-card podium-' + r.rank}>
              <span className="podium-rank num">{r.rank}</span>
              <Link to={`/players/${encodeURIComponent(r.player)}`} className="podium-name">{r.player}</Link>
              <span className="podium-stats">
                <span className="num">{r.titles}</span> {r.titles === 1 ? 'title' : 'titles'} &bull; <span className="num">{r.wins}</span> {r.wins === 1 ? 'win' : 'wins'}
              </span>
            </li>
          ))}
        </ol>
        <div className="rank-card">
        <table className="rtable rank-table">
          <thead>
            <tr>
              <th scope="col">#</th>
              <th scope="col">Player</th>
              <th scope="col" className="num">Titles</th>
              <th scope="col" className="num">Wins</th>
              <th scope="col" className="num">Played</th>
              <th scope="col" className="num">Win rate</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.player}>
                <td className="num">{r.rank}</td>
                <td><Link to={`/players/${encodeURIComponent(r.player)}`} className="rank-player"><span className="rank-avatar" aria-hidden="true">{r.player.charAt(0).toUpperCase()}</span>{r.player}</Link></td>
                <td className="num">{r.titles}</td>
                <td className="num">{r.wins}</td>
                <td className="num">{r.played}</td>
                <td className="num rate">{winRate(r.wins, r.played)}</td>
              </tr>
            ))}
          </tbody>
        </table>
        </div>
        </>
      )}
    </>
  )
}