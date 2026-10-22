import { useState } from 'react'
import { Link, useNavigate } from 'react-router'
import { useAuth } from '../auth/context'
import { useApi } from '../hooks/useApi'
import { TournamentList } from '../model'
import ErrorBanner from '../components/ErrorBanner'

const PATHS = {
  list: 'M5 4h14v16H5zM9 9h6M9 13h6M9 17h3',
  teams: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 20c0-3 3-5 6-5s6 2 6 5M17 11a2.5 2.5 0 1 0 0-6M16 15c3 0 5 2 5 5',
  logout: 'M10 4H5v16h5M15 8l4 4-4 4M19 12H9',
} as const

function Icon({ name }: { name: keyof typeof PATHS }) {
  return (
    <svg className="nav-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d={PATHS[name]} />
    </svg>
  )
}

export default function ProfilePage() {
  const { user, logout } = useAuth()
  const navigate = useNavigate()
  const list = useApi('/me/tournaments', TournamentList)
  const [now] = useState(() => Date.now())

  // ProtectedRoute guarantees this, but keep TypeScript honest.
  if (!user) return null

  const items = list.data ? list.data.tournaments : null
  const upcoming = items
    ? items.filter(
        (t) =>
          t.startTime != null &&
          new Date(t.startTime).getTime() >= now &&
          t.state !== 'Completed' &&
          t.state !== 'Cancelled',
      ).length
    : null

  async function onLogout() {
    await logout()
    navigate('/')
  }

  return (
    <div className="profile">
      <section className="profile-head" aria-label="Profile">
        <span className="profile-avatar" aria-hidden="true">{user.username.charAt(0).toUpperCase()}</span>
        <div>
          <h1 className="profile-name">{user.username}</h1>
          {items !== null && items.length > 0 && <span className="profile-chip">Organizer</span>}
        </div>
      </section>

      {list.error ? (
        <ErrorBanner message={list.error} onRetry={list.retry} />
      ) : (
        <ul className="profile-stats">
          <li>
            <span className="num profile-stat-value">{items ? items.length : '...'}</span>
            <span className="profile-stat-label">Tournaments</span>
          </li>
          <li>
            <span className="num profile-stat-value">{upcoming ?? '...'}</span>
            <span className="profile-stat-label">Upcoming</span>
          </li>
        </ul>
      )}

      <ul className="menu-list">
        <li>
          <Link to="/me" className="menu-row">
            <Icon name="list" />
            <span>My Tournaments</span>
            <span className="menu-chevron" aria-hidden="true">&rsaquo;</span>
          </Link>
        </li>
        <li>
          <Link to="/teams/new" className="menu-row">
            <Icon name="teams" />
            <span>Teams</span>
            <span className="menu-chevron" aria-hidden="true">&rsaquo;</span>
          </Link>
        </li>
        <li>
          <button type="button" className="menu-row" onClick={() => void onLogout()}>
            <Icon name="logout" />
            <span>Log Out</span>
          </button>
        </li>
      </ul>
    </div>
  )
}