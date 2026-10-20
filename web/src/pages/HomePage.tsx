import { Link } from 'react-router'
import { useApi } from '../hooks/useApi'
import { gameLabel, PublicStatsView, TournamentList } from '../model'
import type { Game } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import TournamentCard from '../components/TournamentCard'

// The backend has no "featured" concept: the four newest public
// tournaments that are open for registration or running.
const FEATURED_STATES: readonly string[] = ['RegistrationOpen', 'InProgress']
const POPULAR: readonly Game[] = ['eFootball', 'PubgMobile', 'CallOfDuty']

const PATHS = {
  trophy: 'M8 4h8v5a4 4 0 0 1-8 0V4zM8 6H4v2a3 3 0 0 0 3 3M16 6h4v2a3 3 0 0 1-3 3M12 13v4M8 20h8M10 17h4',
  gamepad: 'M7 8h10a4 4 0 0 1 4 4v1a3 3 0 0 1-5.2 2L14 13h-4l-1.8 2A3 3 0 0 1 3 13v-1a4 4 0 0 1 4-4zM8 10.5v3M6.5 12h3',
  pulse: 'M3 12h4l2-6 4 12 2-6h6',
  players: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c0-4 4-6 8-6s8 2 8 6',
  teams: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 20c0-3 3-5 6-5s6 2 6 5M17 11a2.5 2.5 0 1 0 0-5M16 15c3 0 5 2 5 5',
} as const

function Svg({ name }: { name: keyof typeof PATHS }) {
  return (
    <svg className="panel-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d={PATHS[name]} />
    </svg>
  )
}

function Hero() {
  return (
    <section className="hero" aria-labelledby="hero-title">
      <div className="hero-copy">
        <p className="hero-eyebrow">Welcome to ArenaOS</p>
        <h1 id="hero-title" className="hero-title">
          <span>Real players.</span>
          <span className="hero-accent">Real tournaments.</span>
          <span className="hero-accent">Your stage.</span>
        </h1>
        <p className="hero-text">
          Compete in exciting tournaments, build your team, climb the ranks and be part of a growing gaming community.
        </p>
        <Link to="/tournaments" className="button-link btn-primary">Explore Tournaments &rarr;</Link>
      </div>
    </section>
  )
}

function BandItem({ icon, label, value }: { icon: keyof typeof PATHS; label: string; value: number }) {
  return (
    <li className="band-item">
      <span className="band-icon"><Svg name={icon} /></span>
      <div>
        <p className="band-label">{label}</p>
        <p className="band-value num">{value.toLocaleString('en-US')}</p>
      </div>
    </li>
  )
}

export default function HomePage() {
  const list = useApi('/tournaments', TournamentList, true)
  const stats = useApi('/stats', PublicStatsView, true)

  const featured = list.data
    ? list.data.tournaments
        .filter((t) => FEATURED_STATES.includes(t.state))
        .sort((a, b) => b.tournamentId - a.tournamentId)
        .slice(0, 4)
    : null
  const s = stats.data

  return (
    <>
      <Hero />

      <section className="panel" aria-labelledby="featured-heading">
        <div className="panel-head">
          <h2 id="featured-heading" className="panel-title">
            <Svg name="trophy" />
            Featured Tournaments
          </h2>
          <Link to="/tournaments" className="panel-link">View All &rarr;</Link>
        </div>
        {list.error ? (
          <ErrorBanner message={list.error} onRetry={list.retry} />
        ) : featured === null ? (
          <LoadingBlock label="Loading tournaments" />
        ) : featured.length === 0 ? (
          <EmptyState
            title="Nothing open right now"
            action={<Link to="/tournaments" className="button-link">Browse all tournaments</Link>}
          >
            Tournaments that are open for registration or running show up here.
          </EmptyState>
        ) : (
          <ul className="tcards">
            {featured.map((t) => (
              <TournamentCard key={t.tournamentId} tournament={t} />
            ))}
          </ul>
        )}
      </section>

      <section className="panel" aria-labelledby="popular-heading">
        <div className="panel-head">
          <h2 id="popular-heading" className="panel-title">
            <Svg name="gamepad" />
            Popular Games
          </h2>
          <Link to="/tournaments" className="panel-link">View All &rarr;</Link>
        </div>
        {stats.error ? (
          <ErrorBanner message={stats.error} onRetry={stats.retry} />
        ) : s === null ? (
          <LoadingBlock label="Loading games" />
        ) : (
          <ul className="gtiles">
            {POPULAR.map((g) => {
              const n = s.byGame.find((x) => x.game === g)?.count ?? 0
              return (
                <li key={g} className="gtile">
                  <div className="gtile-art" data-game={g} />
                  <div className="gtile-body">
                    <h3 className="gtile-name">{gameLabel[g]}</h3>
                    <p className="gtile-count">{n} {n === 1 ? 'tournament' : 'tournaments'}</p>
                    <Link to={`/tournaments?game=${g}`} className="gtile-cta">Explore &rarr;</Link>
                  </div>
                </li>
              )
            })}
            <li className="gtile gtile-soon">
              <div className="gtile-body">
                <h3 className="gtile-name">More games</h3>
                <p className="gtile-count">Coming soon</p>
              </div>
            </li>
          </ul>
        )}
      </section>

      <section className="stats-band" aria-label="Platform totals">
        {stats.error ? (
          <ErrorBanner message={stats.error} onRetry={stats.retry} />
        ) : s === null ? (
          <LoadingBlock label="Loading totals" />
        ) : (
          <ul className="band-list">
            <BandItem icon="trophy" label="Total Tournaments" value={s.tournaments} />
            <BandItem icon="pulse" label="Active Tournaments" value={s.activeTournaments} />
            <BandItem icon="players" label="Players" value={s.players} />
            <BandItem icon="teams" label="Registered Teams" value={s.teams} />
          </ul>
        )}
      </section>
    </>
  )
}