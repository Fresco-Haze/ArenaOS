import { useId } from 'react'
import { useGames } from '../lib/useGames'

export const GAME_NAME_MAX = 40

// One box: type to search the list, or type any name for a custom game.
export default function GameField({ value, onChange }: { value: string; onChange: (game: string) => void }) {
  const games = useGames()
  const listId = useId()
  return (
    <label>
      Game (optional)
      <input
        list={listId}
        value={value}
        maxLength={GAME_NAME_MAX}
        autoComplete="off"
        placeholder="Search or type a game"
        onChange={(e) => onChange(e.target.value)}
      />
      <datalist id={listId}>
        {games.map((g) => (
          <option key={g} value={g} />
        ))}
      </datalist>
      <span className="muted">Not in the list? Just type its name.</span>
    </label>
  )
}
