import { useState } from 'react'
import { useGames } from '../lib/useGames'

const CUSTOM = '__custom__'
export const GAME_NAME_MAX = 40

// Pick a game from the list, or choose "Custom game" and type any name.
export default function GameField({ value, onChange }: { value: string; onChange: (game: string) => void }) {
  const games = useGames()
  const [custom, setCustom] = useState(false)
  const typed = value.trim().toLowerCase()
  const match = games.find((g) => g.toLowerCase() === typed)
  const showCustom = custom || (value !== '' && games.length > 0 && !match)
  const selectValue = showCustom ? CUSTOM : (match ?? '')
  return (
    <>
      <label>
        Game (optional)
        <select
          value={selectValue}
          onChange={(e) => {
            const v = e.target.value
            if (v === CUSTOM) { setCustom(true); onChange('') }
            else { setCustom(false); onChange(v) }
          }}
        >
          <option value="">Not set</option>
          {games.map((g) => (
            <option key={g} value={g}>{g}</option>
          ))}
          <option value={CUSTOM}>Custom game&hellip;</option>
        </select>
      </label>
      {showCustom && (
        <label>
          Game name
          <input
            value={value}
            maxLength={GAME_NAME_MAX}
            placeholder="Type the game's name"
            onChange={(e) => onChange(e.target.value)}
          />
        </label>
      )}
    </>
  )
}
