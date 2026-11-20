import { useState } from 'react'
import { Link } from 'react-router'
import { useAuth } from '../auth/context'
import { useApi } from '../hooks/useApi'
import { MatchHistoryList, MyMatchSummary, TeamList, TournamentList } from '../model'
import { formatDateTime } from '../lib/dates'
import { participantName } from '../lib/participants'

import ActivityInvitesCard from '../components/ActivityInvitesCard'
import NextMatchCheckIn from '../components/NextMatchCheckIn'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'
import RecentMatchHistory from '../components/RecentMatchHistory'
import Tabs from '../components/Tabs'
import TeamCrest from '../components/TeamCrest'
import TournamentRow from '../components/TournamentRow'

type TabId = 'created' | 'registered' | 'completed'

const stat = (v: number | null) => (v === null ? '\u2014' : String(v))

export default function MyTournamentsPage() {
  const { user } = useAuth()
  const list = useApi('/me/tournaments', TournamentList)
  const regs = useApi('/me/registrations', TournamentList)
  const summary = useApi('/me/match-summary', MyMatchSummary)
  const teams = useApi('/me/teams', TeamList)
  const history = useApi('/me/match-history', MatchHistoryList)
  const [tab, setTab] = useState<TabId>('created')

  const items = list.data ? list.data.tournaments : null
  const registeredItems = regs.data ? regs.data.tournaments : null
  const created = items ? items.filter((t) => t.state !== 'Completed') : []
  const completed = items ? items.filter((t) => t.state === 'Completed') : []
  const shown = tab === 'created' ? created : tab === 'registered' ? (registeredItems ?? []) : completed
  const current = tab === 'registered' ? regs : list
  const loaded = tab === 'registered' ? registeredItems : items

  const activeRegs = registeredItems
    ? registeredItems.filter((t) => t.state !== 'Completed' && t.state !== 'Cancelled')
    : null
  const liveCount = activeRegs ? activeRegs.filter((t) => t.state === 'InProgress').length : 0
  const teamList = teams.data ? teams.data.teams : null
  const next = summary.data?.nextMatch ?? null

  const played = history.data ? history.data.played : null
  const wins = history.data ? history.data.wins : 0
  const losses = history.data ? history.data.losses : 0
  const decided = wins + losses
  const rate = decided > 0 ? Math.round((wins / decided) * 1000) / 10 : null

  const createLink = (label: string) => (
    <Link to="/me/new" className="button-link btn-primary">
      {label}
    </Link>
  )

  return (
    <div className="mt pc">
      <p className="pc-kicker">Player command</p>
      <PageHeader
        title={`Welcome back, ${user?.username ?? 'player'}`}
        actions={items !== null && items.length === 0 ? undefined : createLink('Create tournament')}
      />

      <section className="pc-stats" aria-label="Your stats">
        <article className="pc-stat">
          <span className="pc-stat-label">Matches played</span>
          <span className="pc-stat-value">{stat(played)}</span>
          <span className="pc-stat-sub">Across all tournaments</span>
        </article>
        <article className="pc-stat">
          <span className="pc-stat-label">Win rate</span>
          <span className="pc-stat-value">{rate === null ? '\u2014' : `${rate}%`}</span>
          <span className={'pc-bar' + (rate === null ? ' pc-bar-empty' : '')} aria-hidden="true">
            <span className="pc-bar-win" style={{ width: `${rate ?? 0}%` }} />
          </span>
          <span className="pc-stat-sub">{wins}W &middot; {losses}L</span>
        </article>
        <article className="pc-stat">
          <span className="pc-stat-label">Active tournaments</span>
          <span className="pc-stat-value">
            {stat(activeRegs ? activeRegs.length : null)}
            {liveCount > 0 && <span className="pc-live"> &#9679; {liveCount} live</span>}
          </span>
          <span className="pc-stat-sub">You are registered in</span>
        </article>
        <article className="pc-stat">
          <span className="pc-stat-label">My teams</span>
          <span className="pc-stat-value">{stat(teamList ? teamList.length : null)}</span>
          <span className="pc-stat-sub">Captain of {teamList ? teamList.length : '\u2014'}</span>
        </article>
      </section>

      {summary.data !== null && (next ? (
        <section className="pc-next" aria-labelledby="pc-next-h">
          <div>
            <p className="pc-next-kicker">
              {next.match.status === 'InProgress' ? 'Match in progress' : 'Next match ready'} &middot; {next.tournamentName}
            </p>
            <h2 id="pc-next-h">
              {participantName(next.match.competitorA)} vs {participantName(next.match.competitorB)}
            </h2>
            <p className="muted">
              {next.match.status === 'InProgress'
                ? 'Live now'
                : next.match.scheduledStart
                  ? formatDateTime(next.match.scheduledStart)
                  : 'Start time to be announced'}
            </p>
          </div>
          <NextMatchCheckIn tournamentId={next.tournamentId} />
          <Link to={`/tournaments/${next.tournamentId}/match/${next.match.nodeId}`} className="button-link btn-primary">
            Enter match lobby
          </Link>
        </section>
      ) : (
        <section className="pc-next pc-next-empty" aria-labelledby="pc-next-h">
          <div>
            <p className="pc-next-kicker">Next match</p>
            <h2 id="pc-next-h">No upcoming match</h2>
            <p className="muted">Register for a tournament and your next match will show up here.</p>
          </div>
          <Link to="/tournaments" className="button-link">Browse tournaments</Link>
        </section>
      ))}

      <div className="pc-grid">
        <div className="pc-main">
          <section aria-label="Active and upcoming tournaments">
            <Tabs<TabId>
              label="My tournaments"
              active={tab}
              onChange={setTab}
              tabs={[
                { id: 'created', label: 'Created', ...(items ? { count: created.length } : {}) },
                { id: 'registered', label: 'Registered', ...(registeredItems ? { count: registeredItems.length } : {}) },
                { id: 'completed', label: 'Completed', ...(items ? { count: completed.length } : {}) },
              ]}
            />
            <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="mt-panel">
              {current.error ? (
                <ErrorBanner message={current.error} onRetry={current.retry} />
              ) : loaded === null ? (
                <LoadingBlock label="Loading tournaments" />
              ) : shown.length === 0 ? (
                tab === 'created' ? (
                  <EmptyState title="No tournaments yet" action={createLink('Create your first tournament')}>
                    Tournaments you create appear here.
                  </EmptyState>
                ) : tab === 'registered' ? (
                  <EmptyState
                    title="Not registered anywhere yet"
                    action={<Link to="/tournaments" className="button-link">Browse tournaments</Link>}
                  >
                    Tournaments you register for appear here.
                  </EmptyState>
                ) : (
                  <EmptyState title="Nothing completed yet">Finished tournaments show up here.</EmptyState>
                )
              ) : (
                <ul className="trows">
                  {shown.map((t) => (
                    <TournamentRow key={t.tournamentId} tournament={t} />
                  ))}
                </ul>
              )}
            </div>
          </section>

          <RecentMatchHistory
            list={history.data ? history.data.matches : null}
            error={history.error}
            onRetry={history.retry}
            wins={wins}
            losses={losses}
          />
        </div>

        <aside className="pc-side">
          <section className="pc-card" aria-labelledby="pc-teams-h">
            <div className="pc-card-head">
              <h2 id="pc-teams-h">My teams</h2>
              <Link to="/teams">Manage</Link>
            </div>
            {teams.error ? (
              <ErrorBanner message={teams.error} onRetry={teams.retry} />
            ) : teamList === null ? (
              <LoadingBlock label="Loading teams" />
            ) : teamList.length === 0 ? (
              <p className="muted">You have not created a team yet. <Link to="/teams">Create one</Link>.</p>
            ) : (
              <ul className="pc-teams">
                {teamList.slice(0, 4).map((t) => (
                  <li key={t.name}>
                    <TeamCrest name={t.name} size={36} team />
                    <span className="pc-team-name">{t.name}</span>
                    <span className="muted">{t.members.length} members</span>
                  </li>
                ))}
              </ul>
            )}
          </section>

          <ActivityInvitesCard />
        </aside>
      </div>
    </div>
  )
}