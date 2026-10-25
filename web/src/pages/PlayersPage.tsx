import { Link, useNavigate, useSearchParams } from 'react-router'
import type { FormEvent } from 'react'
import { useApi } from '../hooks/useApi'
import { PlayerList } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'

export default function PlayersPage() {
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const q = (params.get('q') ?? '').trim()
  const list = useApi(q ? `/players?limit=50&q=${encodeURIComponent(q)}` : '/players?limit=50', PlayerList, true)
  const rows = list.data ? list.data.players : null

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const v = String(new FormData(e.currentTarget).get('q') ?? '').trim()
    navigate(v ? `/players?q=${encodeURIComponent(v)}` : '/players')
  }

  return (
    <>
      <PageHeader title="Players" />
      <form key={q} className="player-search" role="search" onSubmit={submit}>
        <label className="sr-only" htmlFor="player-search-input">Search players</label>
        <input id="player-search-input" name="q" type="search" defaultValue={q} placeholder="Search players by name" autoComplete="off" />
      </form>
      <p className="muted">Players from public tournaments, ranked by titles won, then match wins.</p>
      {list.error ? (
        <ErrorBanner message={list.error} onRetry={list.retry} />
      ) : rows === null ? (
        <LoadingBlock label="Loading players" />
      ) : rows.length === 0 ? (
        <EmptyState
          title={q ? 'No players match' : 'No players yet'}
          action={q ? <Link to="/players" className="button-link">Clear search</Link> : undefined}
        >
          {q ? 'Try a different name.' : 'Players appear once they enter a public tournament.'}
        </EmptyState>
      ) : (
        <table className="rtable">
          <thead>
            <tr>
              <th scope="col">Player</th>
              <th scope="col" className="num">Tournaments</th>
              <th scope="col" className="num">Titles</th>
              <th scope="col" className="num">Wins</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.name}>
                <td><Link to={`/players/${encodeURIComponent(r.name)}`}>{r.name}</Link></td>
                <td className="num">{r.tournaments}</td>
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