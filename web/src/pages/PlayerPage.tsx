import { Link, useParams } from 'react-router'
import { useApi } from '../hooks/useApi'
import { PlayerProfileView, gameLabel } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import TournamentCard from '../components/TournamentCard'

function Stat({ value, label }: { value: number; label: string }) {
  return (
    <li className="pf-stat">
      <span className="num profile-stat-value">{value}</span>
      <span className="profile-stat-label">{label}</span>
    </li>
  )
}

export default function PlayerPage() {
  const { name = '' } = useParams()
  const profile = useApi(`/players/${encodeURIComponent(name)}`, PlayerProfileView, true)
  const p = profile.data

  if (profile.error === 'Player not found') {
    return (
      <EmptyState
        title="Player not found"
        action={<Link to="/players" className="button-link">Browse players</Link>}
      >
        No public tournament lists a player with this exact name.
      </EmptyState>
    )
  }
  if (profile.error) return <ErrorBanner message={profile.error} onRetry={profile.retry} />
  if (p === null) return <LoadingBlock label="Loading player" />

  const won = p.history.filter((h) => h.champion)
  const gameCounts = new Map<string, number>()
  for (const h of p.history) {
    const g = h.tournament.game
    if (g && g !== 'Other') gameCounts.set(gameLabel[g], (gameCounts.get(gameLabel[g]) ?? 0) + 1)
  }
  const games = [...gameCounts.entries()].sort((a, b) => b[1] - a[1])

  return (
    <div className="pf">
      <nav aria-label="Breadcrumb" className="tp-crumbs muted">
        <Link to="/players">Players</Link>
        <span aria-hidden="true">&rsaquo;</span>
        <span>{p.name}</span>
      </nav>

      <section className="pf-head" aria-label="Player">
        <div className="pf-id">
          <span className="profile-avatar" aria-hidden="true">{p.name.charAt(0).toUpperCase()}</span>
          <div>
            <h1 className="profile-name">{p.name}</h1>
            <p className="muted">Based on public tournaments</p>
            {p.titles > 0 && (
              <div className="pf-badges">
                <span className="profile-chip">Champion</span>
              </div>
            )}
          </div>
        </div>
        <ul className="pf-stats">
          <Stat value={p.tournaments} label="Tournaments" />
          <Stat value={p.titles} label="Titles" />
          <Stat value={p.wins} label="Match wins" />
        </ul>
      </section>

      {won.length > 0 && (
        <>
          <h2 className="tp-section-title">Champion of</h2>
          <nav className="chips" aria-label="Tournaments won">
            {won.map((h) => (
              <Link key={h.tournament.tournamentId} to={`/tournaments/${h.tournament.tournamentId}`} className="chip">
                {h.tournament.name}
              </Link>
            ))}
          </nav>
        </>
      )}

      {games.length > 0 && (
        <>
          <h2 className="tp-section-title">Games played</h2>
          <ul className="pf-games">
            {games.map(([name, count]) => (
              <li key={name} className="pf-game"><span>{name}</span><span className="num">{count}</span></li>
            ))}
          </ul>
        </>
      )}

      <h2 className="tp-section-title">Tournaments</h2>
      <ul className="tcards">
        {p.history.map((h) => (
          <TournamentCard key={h.tournament.tournamentId} tournament={h.tournament} showOrganizer />
        ))}
      </ul>
    </div>
  )
}