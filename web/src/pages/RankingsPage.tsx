import { Link, useSearchParams } from 'react-router'
import { useApi } from '../hooks/useApi'
import { Game, RankingList, gameLabel } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'

export default function RankingsPage() {
  const [params] = useSearchParams()
  const parsed = Game.safeParse(params.get('game'))
  const game = parsed.success ? parsed.data : ''
  const list = useApi(game ? `/rankings?limit=50&game=${game}` : '/rankings?limit=50', RankingList, true)
  const rows = list.data ? list.data.rankings : null
  const href = (g: string) => (g ? `/rankings?game=${g}` : '/rankings')

  return (
    <>
      <PageHeader title="Rankings" />
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
      <p className="muted">
        Ranked by titles won, then match wins. Only public tournaments count. Players with the same record share a rank.
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
        <table className="rtable">
          <thead>
            <tr>
              <th scope="col">#</th>
              <th scope="col">Player</th>
              <th scope="col" className="num">Titles</th>
              <th scope="col" className="num">Wins</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.player}>
                <td className="num">{r.rank}</td>
                <td><Link to={`/players/${encodeURIComponent(r.player)}`}>{r.player}</Link></td>
                <td className="num">{r.titles}</td>
                <td className="num">{r.wins}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  )
}