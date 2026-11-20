import { Link, useNavigate } from 'react-router'
import { useGames } from '../lib/useGames'

// Up to this many games: tabs. More than that: a dropdown, so the strip never needs sideways scrolling.
const MAX_TABS = 8

export default function GameFilter({ current, href }: { current: string; href: (g: string) => string }) {
  const navigate = useNavigate()
  const games = useGames()
  const typed = current.trim().toLowerCase()
  const match = games.find((g) => g.toLowerCase() === typed)
  const active = match ?? current
  const extra = current !== '' && !match ? [current] : []

  if (games.length > MAX_TABS) {
    return (
      <nav className="chips game-select" aria-label="Filter by game">
        <select aria-label="Game" value={active} onChange={(e) => navigate(href(e.target.value))}>
          <option value="">All games</option>
          {[...games, ...extra].map((g) => (
            <option key={g} value={g}>{g}</option>
          ))}
        </select>
      </nav>
    )
  }

  return (
    <nav className="chips game-tabs" aria-label="Filter by game">
      {['', ...games, ...extra].map((g) => (
        <Link key={g || 'all'} to={href(g)} className="chip" aria-current={g === active ? 'true' : undefined}>
          {g || 'All games'}
        </Link>
      ))}
    </nav>
  )
}