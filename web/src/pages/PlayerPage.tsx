import { Link, useParams } from 'react-router'
import { useApi } from '../hooks/useApi'
import { PlayerProfileView } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'
import TournamentCard from '../components/TournamentCard'

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

  return (
    <>
      <PageHeader title={p.name} meta="Based on public tournaments" />
      <ul className="profile-stats">
        <li>
          <span className="num profile-stat-value">{p.tournaments}</span>
          <span className="profile-stat-label">Tournaments</span>
        </li>
        <li>
          <span className="num profile-stat-value">{p.titles}</span>
          <span className="profile-stat-label">Titles</span>
        </li>
        <li>
          <span className="num profile-stat-value">{p.wins}</span>
          <span className="profile-stat-label">Match wins</span>
        </li>
      </ul>

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

      <h2 className="tp-section-title">Tournaments</h2>
      <ul className="tcards">
        {p.history.map((h) => (
          <TournamentCard key={h.tournament.tournamentId} tournament={h.tournament} showOrganizer />
        ))}
      </ul>
    </>
  )
}