import { useState } from 'react'
import { Link, useNavigate } from 'react-router'
import { useAuth } from '../auth/context'
import { useApi } from '../hooks/useApi'
import { MyMatchSummary, TeamList, TournamentList } from '../model'
import type { Tournament } from '../model'
import Avatar from '../components/Avatar'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import Tabs from '../components/Tabs'
import TournamentRow from '../components/TournamentRow'

const PATHS = {
  list: 'M5 4h14v16H5zM9 9h6M9 13h6M9 17h3',
  teams: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 20c0-3 3-5 6-5s6 2 6 5M17 11a2.5 2.5 0 1 0 0-6M16 15c3 0 5 2 5 5',
  logout: 'M10 4H5v16h5M15 8l4 4-4 4M19 12H9',
  settings: 'M4 7h9M17 7h3M4 17h3M11 17h9M15 4v6M9 14v6',
  help: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.5M12 17h.01',
  lock: 'M7 11V8a5 5 0 0 1 10 0v3M5 11h14v9H5z',
  edit: 'M4 20h4L19 9l-4-4L4 16zM13 7l4 4',
  image: 'M4 5h16v14H4zM4 17l5-5 4 4 3-3 4 4',
} as const

type TabId = 'overview' | 'tournaments' | 'teams'

function Icon({ name }: { name: keyof typeof PATHS }) {
  return (
    <svg className="nav-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d={PATHS[name]} />
    </svg>
  )
}

function Stat({ value, label }: { value: number | null; label: string }) {
  return (
    <li className="pf-stat">
      <span className="num profile-stat-value">{value === null ? '...' : value}</span>
      <span className="profile-stat-label">{label}</span>
    </li>
  )
}

function Chevron() {
  return <span className="menu-chevron" aria-hidden="true">&rsaquo;</span>
}

function TournamentSection({
  title,
  items,
  error,
  retry,
  empty,
}: {
  title: string
  items: Tournament[] | null
  error: string | null
  retry: () => void
  empty: string
}) {
  return (
    <section className="pf-section">
      <h2 className="tp-section-title">{title}</h2>
      {error ? (
        <ErrorBanner message={error} onRetry={retry} />
      ) : items === null ? (
        <LoadingBlock label="Loading tournaments" />
      ) : items.length === 0 ? (
        <EmptyState title={empty} />
      ) : (
        <ul className="trows">
          {items.map((t) => (
            <TournamentRow key={t.tournamentId} tournament={t} />
          ))}
        </ul>
      )}
    </section>
  )
}

export default function ProfilePage() {
  const { user, logout } = useAuth()
  const navigate = useNavigate()
  const created = useApi('/me/tournaments', TournamentList)
  const joined = useApi('/me/registrations', TournamentList)
  const teams = useApi('/me/teams', TeamList)
  const summary = useApi('/me/match-summary', MyMatchSummary)
  const [tab, setTab] = useState<TabId>('overview')

  // ProtectedRoute guarantees this, but keep TypeScript honest.
  if (!user) return null

  const createdItems = created.data ? created.data.tournaments : null
  const joinedItems = joined.data ? joined.data.tournaments : null
  const teamItems = teams.data ? teams.data.teams : null
  const tournamentCount = createdItems !== null && joinedItems !== null ? createdItems.length + joinedItems.length : null

  async function onLogout() {
    await logout()
    navigate('/')
  }

  return (
    <div className="pf">
      <section className="pf-head" aria-label="Profile">
        <div className="pf-id">
          <Avatar className="profile-avatar" />
          <div>
            <h1 className="profile-name">{user.fullName || user.username}</h1>
            {user.fullName && <p className="muted">@{user.username}</p>}
            <div className="pf-badges">
              {createdItems !== null && createdItems.length > 0 && <span className="profile-chip">Organizer</span>}
              <Link to="/settings" className="button-link pf-edit">Edit profile</Link>
            </div>
          </div>
        </div>
        <ul className="pf-stats">
          <Stat value={createdItems ? createdItems.length : null} label="Tournaments Created" />
          <Stat value={joinedItems ? joinedItems.length : null} label="Tournaments Joined" />
          <Stat value={summary.data ? summary.data.tournamentsWon : null} label="Tournaments Won" />
        </ul>
      </section>

      <Tabs<TabId>
        label="Profile sections"
        active={tab}
        onChange={setTab}
        tabs={[
          { id: 'overview', label: 'Overview' },
          { id: 'tournaments', label: 'Tournaments', ...(tournamentCount !== null ? { count: tournamentCount } : {}) },
          { id: 'teams', label: 'Teams', ...(teamItems ? { count: teamItems.length } : {}) },
        ]}
      />

      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`}>
        {tab === 'overview' && (
          <div className="pf-panels">
            <section className="pf-panel" aria-labelledby="pf-personal">
              <div className="pf-panel-head">
                <h2 id="pf-personal">Personal Information</h2>
                <Link to="/settings" className="panel-link">Edit</Link>
              </div>
              <dl className="pf-dl">
                <div>
                  <dt>Username</dt>
                  <dd>@{user.username}</dd>
                </div>
                <div>
                  <dt>Full name</dt>
                  <dd>{user.fullName || 'Not set'}</dd>
                </div>
              </dl>
            </section>

            <section className="pf-panel" aria-labelledby="pf-account">
              <div className="pf-panel-head">
                <h2 id="pf-account">Account Settings</h2>
              </div>
              <ul className="menu-list">
                <li>
                  <Link to="/settings" className="menu-row">
                    <Icon name="lock" />
                    <span>Change password</span>
                    <Chevron />
                  </Link>
                </li>
                <li>
                  <Link to="/settings" className="menu-row">
                    <Icon name="edit" />
                    <span>Edit name</span>
                    <Chevron />
                  </Link>
                </li>
                <li>
                  <Link to="/settings" className="menu-row">
                    <Icon name="image" />
                    <span>Change picture</span>
                    <Chevron />
                  </Link>
                </li>
                <li>
                  <Link to="/help" className="menu-row">
                    <Icon name="help" />
                    <span>Help</span>
                    <Chevron />
                  </Link>
                </li>
                <li>
                  <button type="button" className="menu-row" onClick={() => void onLogout()}>
                    <Icon name="logout" />
                    <span>Log Out</span>
                  </button>
                </li>
              </ul>
            </section>
          </div>
        )}

        {tab === 'tournaments' && (
          <>
            <TournamentSection
              title="Created by you"
              items={createdItems}
              error={created.error}
              retry={created.retry}
              empty="You have not created a tournament yet"
            />
            <TournamentSection
              title="Joined"
              items={joinedItems}
              error={joined.error}
              retry={joined.retry}
              empty="You have not joined a tournament yet"
            />
          </>
        )}

        {tab === 'teams' && (
          <section className="pf-section">
            <div className="pf-panel-head">
              <h2 className="tp-section-title">Your teams</h2>
              <Link to="/teams/new" className="panel-link">Create team</Link>
            </div>
            {teams.error ? (
              <ErrorBanner message={teams.error} onRetry={teams.retry} />
            ) : teamItems === null ? (
              <LoadingBlock label="Loading teams" />
            ) : teamItems.length === 0 ? (
              <EmptyState
                title="No teams yet"
                action={<Link to="/teams/new" className="button-link">Create a team</Link>}
              >
                Teams you create appear here.
              </EmptyState>
            ) : (
              <ul className="pf-teams">
                {teamItems.map((tm) => (
                  <li key={tm.name} className="pf-team">
                    <span className="pf-team-name">{tm.name}</span>
                    <span className="muted">Captain: {tm.captain}</span>
                    <span className="muted">{tm.members.join(', ')}</span>
                  </li>
                ))}
              </ul>
            )}
          </section>
        )}
      </div>
    </div>
  )
}