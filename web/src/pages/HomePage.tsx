import { useState } from 'react'
import type { ReactNode } from 'react'
import { Link } from 'react-router'
import { useApi } from '../hooks/useApi'
import { startsIn, timeAgo } from '../lib/cardDate'
import { formatKes } from '../lib/money'
import { ActivityList, gameLabel, PublicStatsView, RankingList, TournamentList } from '../model'
import type { ActivityItem, Game } from '../model'
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
  calendar: 'M4 6h16v14H4zM4 10h16M8 3v4M16 3v4',
} as const

type IconName = keyof typeof PATHS

function Svg({ name }: { name: IconName }) {
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

const num = (n: number) => n.toLocaleString('en-US')

function BandItem({ icon, label, value }: { icon: IconName; label: string; value: string }) {
  return (
    <li className="band-item">
      <span className="band-icon"><Svg name={icon} /></span>
      <div>
        <p className="band-label">{label}</p>
        <p className="band-value num">{value}</p>
      </div>
    </li>
  )
}

function RailPanel({
  id, icon, title, soon, link, children,
}: { id: string; icon: IconName; title: string; soon?: boolean; link?: ReactNode; children: ReactNode }) {
  return (
    <section className="panel" aria-labelledby={id}>
      <div className="panel-head">
        <h2 id={id} className="panel-title panel-title-sm">
          <Svg name={icon} />
          {title}
        </h2>
        {soon && <span className="soon-tag">Soon</span>}
        {link}
      </div>
      {children}
    </section>
  )
}

function UpcomingPanel() {
  const up = useApi('/tournaments?upcoming=1&limit=4', TournamentList, true)
  const [now] = useState(() => Date.now())
  const items = up.data ? up.data.tournaments : null
  return (
    <RailPanel
      id="upcoming-heading"
      icon="calendar"
      title="Upcoming Tournaments"
      link={<Link to="/tournaments" className="panel-link">View All &rarr;</Link>}
    >
      {up.error ? (
        <ErrorBanner message={up.error} onRetry={up.retry} />
      ) : items === null ? (
        <LoadingBlock label="Loading upcoming tournaments" />
      ) : items.length === 0 ? (
        <p className="muted rail-empty">Tournaments with a start time show up here.</p>
      ) : (
        <ul className="urows">
          {items.map((t) => {
            const mode = t.participantMode === 'SquadOnly' ? 'Squad' : '1v1'
            const game = t.game && t.game !== 'Other' ? gameLabel[t.game] : null
            return (
              <li key={t.tournamentId} className="urow">
                <div className="urow-art" data-game={t.game ?? 'none'} aria-hidden="true" />
                <div className="urow-main">
                  <Link to={`/tournaments/${t.tournamentId}`} className="urow-name">{t.name}</Link>
                  <p className="urow-sub">{game ? `${game} \u2022 ${mode}` : mode}</p>
                </div>
                <span className="urow-when">{t.startTime ? startsIn(t.startTime, now) : ''}</span>
              </li>
            )
          })}
        </ul>
      )}
    </RailPanel>
  )
}

function TopPlayersPanel() {
  const top = useApi('/rankings', RankingList, true)
  const rows = top.data ? top.data.rankings : null
  return (
    <RailPanel id="top-players-heading" icon="trophy" title="Top Players (Global)">
      {top.error ? (
        <ErrorBanner message={top.error} onRetry={top.retry} />
      ) : rows === null ? (
        <LoadingBlock label="Loading rankings" />
      ) : rows.length === 0 ? (
        <p className="muted rail-empty">Rankings appear once matches have been played.</p>
      ) : (
        <ol className="rrows">
          {rows.map((r, i) => (
            <li key={r.player} className="rrow">
              <span className="rrow-rank num">{i + 1}</span>
              <span className="rrow-name">{r.player}</span>
              <span className="rrow-stat num">
                {r.titles} {r.titles === 1 ? 'title' : 'titles'} &bull; {r.wins} {r.wins === 1 ? 'win' : 'wins'}
              </span>
            </li>
          ))}
        </ol>
      )}
    </RailPanel>
  )
}

const ACTIVITY_TEXT: Record<ActivityItem['event'], string> = {
  Published: 'Published',
  RegistrationOpened: 'Registration opened',
  Started: 'Started',
  Completed: 'Completed',
  Cancelled: 'Cancelled',
  Reopened: 'Reopened',
  Other: 'Updated',
}

function ActivityPanel() {
  const act = useApi('/activity', ActivityList, true)
  const [now] = useState(() => Date.now())
  const items = act.data ? act.data.activity : null
  return (
    <RailPanel id="activity-heading" icon="pulse" title="Recent Activity">
      {act.error ? (
        <ErrorBanner message={act.error} onRetry={act.retry} />
      ) : items === null ? (
        <LoadingBlock label="Loading activity" />
      ) : items.length === 0 ? (
        <p className="muted rail-empty">Tournament activity will appear here.</p>
      ) : (
        <ul className="arows">
          {items.map((a, i) => (
            <li key={i} className="arow">
              <Link to={`/tournaments/${a.tournamentId}`} className="arow-name">{a.name}</Link>
              <p className="arow-sub">{ACTIVITY_TEXT[a.event]} &bull; {timeAgo(a.at, now)}</p>
            </li>
          ))}
        </ul>
      )}
    </RailPanel>
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
    <div className="home-grid">
      <div className="home-main">
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
            <ul className="tcards tcards-featured">
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
              <BandItem icon="trophy" label="Total Tournaments" value={num(s.tournaments)} />
              <BandItem icon="players" label="Players" value={num(s.players)} />
              <BandItem icon="teams" label="Registered Teams" value={num(s.teams)} />
              <BandItem icon="trophy" label="Total Prize Pool" value={formatKes(s.prizePool)} />
            </ul>
          )}
        </section>
      </div>

      <aside className="home-rail" aria-label="Side panels">
        <RailPanel id="next-match-heading" icon="calendar" title="Next Match" soon>
          <p className="muted rail-empty">Not available yet. This will show your next scheduled match.</p>
        </RailPanel>
        <UpcomingPanel />
        <ActivityPanel />
        <TopPlayersPanel />
      </aside>
    </div>
  )
}