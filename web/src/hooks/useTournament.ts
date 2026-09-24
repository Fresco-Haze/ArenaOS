import { useCallback, useEffect, useRef, useState } from 'react'
import { api, ApiError } from '../api'
import { BracketView, TournamentView } from '../model'

const POLL_MS = 20_000

type Data = {
  view: TournamentView
  bracket: BracketView | null
  lastUpdated: number
}

export type TournamentLoad =
  | { kind: 'loading' }
  | { kind: 'notfound' }
  | { kind: 'error'; message: string }
  | { kind: 'ready'; data: Data; refreshFailed: boolean; refreshing: boolean }

async function fetchAll(id: string): Promise<Data> {
  const [view, bracket] = await Promise.all([
    api(`/tournaments/${id}`, TournamentView, { retryAnonymously: true }),
    api(`/tournaments/${id}/bracket`, BracketView, { retryAnonymously: true }).catch(
      (e: unknown) => {
        // "No bracket yet" is a normal state, not an error.
        if (e instanceof ApiError && e.code === 'BRACKET_NOT_GENERATED') return null
        throw e
      },
    ),
  ])
  return { view, bracket, lastUpdated: Date.now() }
}

export function useTournament(id: string) {
  const [state, setState] = useState<TournamentLoad>({ kind: 'loading' })
  const latest = useRef(0)

  const reload = useCallback(async () => {
    const mine = ++latest.current
    setState((prev) => (prev.kind === 'ready' ? { ...prev, refreshing: true } : prev))
    try {
      const data = await fetchAll(id)
      if (mine !== latest.current) return // a newer request superseded this one
      setState({ kind: 'ready', data, refreshFailed: false, refreshing: false })
    } catch (e) {
      if (mine !== latest.current) return
      if (e instanceof ApiError && (e.code === 'NOT_FOUND' || e.code === 'BAD_REQUEST')) {
        setState({ kind: 'notfound' })
        return
      }
      const message = e instanceof ApiError ? e.message : 'Could not reach the server'
      // Keep the last good data on screen; only flag that the refresh failed.
      setState((prev) =>
        prev.kind === 'ready'
          ? { ...prev, refreshFailed: true, refreshing: false }
          : { kind: 'error', message },
      )
    }
  }, [id])

  // First load.
  useEffect(() => {
    void reload()
  }, [reload])

  // Polling: only when we have data, the tournament isn't over, and the tab is visible.
  const active =
    state.kind === 'ready' &&
    state.data.view.tournament.state !== 'Completed' &&
    state.data.view.tournament.state !== 'Cancelled'

  useEffect(() => {
    if (!active) return
    let timer: ReturnType<typeof setInterval> | undefined

    function stop() {
      if (timer !== undefined) clearInterval(timer)
      timer = undefined
    }
    function start() {
      stop()
      timer = setInterval(() => void reload(), POLL_MS)
    }
    function onVisibility() {
      if (document.visibilityState === 'visible') {
        void reload() // catch up right away when the tab comes back
        start()
      } else {
        stop()
      }
    }

    if (document.visibilityState === 'visible') start()
    document.addEventListener('visibilitychange', onVisibility)

    return () => {
      stop()
      document.removeEventListener('visibilitychange', onVisibility)
    }
  }, [active, reload])

  return { state, reload }
}