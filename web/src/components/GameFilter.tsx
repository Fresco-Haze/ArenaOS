import { useNavigate } from 'react-router'
import { useGames } from '../lib/useGames'

// One dropdown instead of a chip per game. Picking a game changes the page's ?game= filter.
export default function GameFilter({ current, href }: { current: string; href: (g: string) => string }) {
  const navigate = useNavigate()
  const games = useGames()
  const typed = current.trim().toLowerCase()
  const match = games.find((g) => g.toLowerCase() === typed)
  return (
    <nav className="chips" aria-label="Filter by game">
      <select
        aria-label="Game"
        value={match ?? current}
        onChange={(e) => navigate(href(e.target.value))}
      >
        <option value="">All games</option>
        {games.map((g) => (
          <option key={g} value={g}>{g}</option>
        ))}
        {current !== '' && !match && <option value={current}>{current}</option>}
      </select>
    </nav>
  )
}
