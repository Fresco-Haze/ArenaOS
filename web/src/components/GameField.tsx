import { useEffect, useId, useMemo, useState } from 'react'
import type { KeyboardEvent } from 'react'
import { useGames } from '../lib/useGames'
import '../game-field.css'

export const GAME_NAME_MAX = 40

// One box with our own suggestion list: click or type to search, or type any name.
export default function GameField({ value, onChange }: { value: string; onChange: (game: string) => void }) {
  const games = useGames()
  const listId = useId()
  const [open, setOpen] = useState(false)
  const [active, setActive] = useState(-1)
  const q = value.trim().toLowerCase()
  const matches = useMemo(
    () => (q === '' ? games : games.filter((g) => g.toLowerCase().includes(q))),
    [games, q],
  )
  const shown = open && matches.length > 0

  useEffect(() => {
    if (active >= 0) document.getElementById(`${listId}-${active}`)?.scrollIntoView({ block: 'nearest' })
  }, [active, listId])

  function pick(g: string) {
    onChange(g)
    setOpen(false)
    setActive(-1)
  }

  function onKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setOpen(true)
      setActive((i) => Math.min(i + 1, matches.length - 1))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActive((i) => Math.max(i - 1, 0))
    } else if (e.key === 'Enter' && shown && active >= 0) {
      e.preventDefault()
      pick(matches[active])
    } else if (e.key === 'Escape') {
      setOpen(false)
    }
  }

  return (
    <div className="game-field">
      <label>
        Game (optional)
        <input
          role="combobox"
          aria-expanded={shown}
          aria-controls={listId}
          aria-autocomplete="list"
          aria-activedescendant={shown && active >= 0 ? `${listId}-${active}` : undefined}
          value={value}
          maxLength={GAME_NAME_MAX}
          autoComplete="off"
          placeholder="Search or type a game"
          onChange={(e) => {
            onChange(e.target.value)
            setOpen(true)
            setActive(-1)
          }}
          onFocus={() => setOpen(true)}
          onBlur={() => setOpen(false)}
          onKeyDown={onKeyDown}
        />
      </label>
      {shown && (
        <ul id={listId} role="listbox" className="game-list" onMouseDown={(e) => e.preventDefault()}>
          {matches.map((g, i) => (
            <li
              key={g}
              id={`${listId}-${i}`}
              role="option"
              aria-selected={i === active}
              className={i === active ? 'game-opt active' : 'game-opt'}
              onClick={() => pick(g)}
            >
              {g}
            </li>
          ))}
        </ul>
      )}
      <p className="muted game-hint">Not in the list? Just type its name.</p>
    </div>
  )
}
