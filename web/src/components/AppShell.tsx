import { useEffect, useRef, useState } from 'react'
import type { FormEvent, ReactNode } from 'react'
import { Link, NavLink, useLocation, useNavigate } from 'react-router'
import { useAuth } from '../auth/context'
import Logo from './Logo'

const ICONS = {
  home: 'M3 11l9-8 9 8M5 10v10h5v-6h4v6h5V10',
  trophy: 'M8 4h8v5a4 4 0 0 1-8 0V4zM8 6H4v2a3 3 0 0 0 3 3M16 6h4v2a3 3 0 0 1-3 3M12 13v4M8 20h8M10 17h4',
  list: 'M5 4h14v16H5zM9 9h6M9 13h6M9 17h3',
  teams: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 20c0-3 3-5 6-5s6 2 6 5M17 11a2.5 2.5 0 1 0 0-5M16 15c3 0 5 2 5 5',
  games: 'M7 8h10a4 4 0 0 1 4 4v1a3 3 0 0 1-5.2 2L14 13h-4l-1.8 2A3 3 0 0 1 3 13v-1a4 4 0 0 1 4-4zM8 10.5v3M6.5 12h3',
  players: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c0-4 4-6 8-6s8 2 8 6',
  rankings: 'M5 20V10M12 20V4M19 20v-7',
  news: 'M5 4h11v16H5zM16 8h3v10a2 2 0 0 1-2 2M8 8h5M8 12h5M8 16h3',
  store: 'M4 8h16l-1 4H5zM6 12v8h12v-8M10 20v-5h4v5',
  plus: 'M12 5v14M5 12h14',
  search: 'M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14zM20 20l-4-4',
  chevron: 'M6 9l6 6 6-6',
} as const

type IconName = keyof typeof ICONS

function Icon({ name }: { name: IconName }) {
  return (
    <svg className="nav-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d={ICONS[name]} />
    </svg>
  )
}

function SearchBar() {
  const navigate = useNavigate()
  const { search } = useLocation()
  const current = new URLSearchParams(search).get('q') ?? ''

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const q = String(new FormData(e.currentTarget).get('q') ?? '').trim()
    navigate(q ? `/tournaments?q=${encodeURIComponent(q)}` : '/tournaments')
  }

  return (
    <form key={current} className="shell-search" role="search" onSubmit={submit}>
      <Icon name="search" />
      <label className="sr-only" htmlFor="shell-search-input">Search tournaments</label>
      <input
        id="shell-search-input"
        name="q"
        type="search"
        defaultValue={current}
        placeholder="Search tournaments by name"
        autoComplete="off"
      />
    </form>
  )
}

function UserMenu() {
  const { user, logout } = useAuth()
  const [open, setOpen] = useState(false)
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    function onDown(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false)
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') setOpen(false)
    }
    document.addEventListener('mousedown', onDown)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('mousedown', onDown)
      document.removeEventListener('keydown', onKey)
    }
  }, [open])

  if (!user) {
    return <Link to="/login" className="button-link btn-primary">Sign in</Link>
  }

  return (
    <div className="user-menu" ref={ref}>
      <button
        type="button"
        className="user-trigger"
        aria-expanded={open}
        onClick={() => setOpen((o) => !o)}
      >
        <span className="avatar" aria-hidden="true">{user.username.charAt(0).toUpperCase()}</span>
        <span className="user-name">{user.username}</span>
        <Icon name="chevron" />
      </button>
      {open && (
        <div className="user-dropdown">
          <Link to="/me" className="menu-item" onClick={() => setOpen(false)}>My tournaments</Link>
          <button
            type="button"
            className="menu-item"
            onClick={() => {
              setOpen(false)
              void logout()
            }}
          >
            Sign out
          </button>
        </div>
      )}
    </div>
  )
}

function SideLink({ to, icon, end, children }: { to: string; icon: IconName; end?: boolean; children: ReactNode }) {
  return (
    <li>
      <NavLink to={to} end={end} className="side-link">
        <Icon name={icon} />
        <span>{children}</span>
      </NavLink>
    </li>
  )
}

function SoonItem({ icon, children }: { icon: IconName; children: ReactNode }) {
  return (
    <li>
      <span className="side-link side-soon" aria-disabled="true">
        <Icon name={icon} />
        <span>{children}</span>
        <span className="soon-tag">Soon</span>
      </span>
    </li>
  )
}

function SideNav() {
  const { user } = useAuth()
  return (
    <aside className="shell-side">
      <nav aria-label="Main">
        <ul className="side-list">
          <SideLink to="/" icon="home" end>Home</SideLink>
          <SideLink to="/tournaments" icon="trophy">Tournaments</SideLink>
          {user && <SideLink to="/me" icon="list" end>My Tournaments</SideLink>}
          <SideLink to="/teams/new" icon="teams">Teams</SideLink>
        </ul>
        <hr className="side-rule" />
        <ul className="side-list" aria-label="Coming soon">
          <SoonItem icon="games">Games</SoonItem>
          <SoonItem icon="players">Players</SoonItem>
          <SoonItem icon="rankings">Rankings</SoonItem>
          <SoonItem icon="news">News</SoonItem>
          <SoonItem icon="store">Store</SoonItem>
        </ul>
      </nav>
      <section aria-labelledby="quick-actions-heading">
        <h2 id="quick-actions-heading" className="side-group-label">Quick actions</h2>
        <div className="qa-list">
          <Link to="/me/new" className="qa-primary">
            <Icon name="plus" />
            <span>Create Tournament</span>
          </Link>
          <Link to="/teams/new" className="qa-secondary">
            <Icon name="teams" />
            <span>Create Team</span>
          </Link>
        </div>
      </section>
    </aside>
  )
}

function TabLink({ to, icon, end, children }: { to: string; icon: IconName; end?: boolean; children: ReactNode }) {
  return (
    <NavLink to={to} end={end} className="tab-link">
      <Icon name={icon} />
      <span>{children}</span>
    </NavLink>
  )
}

function TabBar() {
  const { user } = useAuth()
  return (
    <nav className="shell-tabbar" aria-label="Primary">
      <TabLink to="/" icon="home" end>Home</TabLink>
      <TabLink to="/tournaments" icon="trophy">Tournaments</TabLink>
      <TabLink to="/me/new" icon="plus">Create</TabLink>
      <TabLink to="/teams/new" icon="teams">Teams</TabLink>
      <TabLink to={user ? '/me' : '/login'} icon="players">{user ? 'Account' : 'Sign in'}</TabLink>
    </nav>
  )
}

export default function AppShell({ children }: { children: ReactNode }) {
  return (
    <div className="shell">
      <a className="skip-link" href="#main">Skip to content</a>
      <header className="shell-top">
        <Link to="/" className="brand brand-wrap" aria-label="ArenaOS home">
          <Logo />
          <span className="brand-tag">Play &middot; Compete &middot; Win</span>
        </Link>
        <SearchBar />
        <div className="shell-top-right">
          <UserMenu />
        </div>
      </header>
      <SideNav />
      <main id="main" className="shell-main">
        {children}
      </main>
      <footer className="shell-foot">
        <Link to="/" className="brand" aria-label="ArenaOS home"><Logo /></Link>
        <p>Tournament management for competitive gaming.</p>
      </footer>
      <TabBar />
    </div>
  )
}