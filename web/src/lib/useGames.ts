import { useEffect, useState } from 'react'
import { api } from '../api'
import { GameList } from '../model'

// Every game name, A to Z. Empty until the list has loaded.
export function useGames(): string[] {
  const [games, setGames] = useState<string[]>([])
  useEffect(() => {
    let alive = true
    api('/games', GameList, { retryAnonymously: true })
      .then((r) => { if (alive) setGames(r.map((x) => x.name)) })
      .catch((err) => { console.error('useGames: could not load /games', err) })
    return () => { alive = false }
  }, [])
  return games
}
