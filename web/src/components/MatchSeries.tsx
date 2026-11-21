import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import { useStickyApi } from '../hooks/useStickyApi'
import { confirmGame, reportGame, setSeriesLength } from '../lib/matchRoomActions'
import { SeriesView } from '../model'

// Game-by-game scoring. A captain reports a game, the other captain confirms it, and staff can
// record or override any game. Signed-out visitors and people outside the match see nothing.
export default function MatchSeries({
  matchId,
  tournamentId,
  nameA,
  nameB,
  isOwner,
  onSettled,
}: {
  matchId: number
  tournamentId: number
  nameA: string
  nameB: string
  isOwner: boolean
  onSettled: () => Promise<void>
}) {
  const series = useStickyApi(`/matches/${matchId}/series`, SeriesView)
  const [picked, setPicked] = useState<number | null>(null)
  const [a, setA] = useState('')
  const [b, setB] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const d = series.data
  if (!d) return null

  const byNo = new Map(d.games.map((g) => [g.no, g]))
  const nums = Array.from({ length: d.bestOf }, (_, i) => i + 1)
  const winsA = d.games.filter((g) => g.confirmed && g.a > g.b).length
  const winsB = d.games.filter((g) => g.confirmed && g.b > g.a).length
  const reportable = nums.filter((n) => (n === 1 || byNo.get(n - 1)?.confirmed === true) && (d.staff || byNo.get(n)?.confirmed !== true))
  const current = picked !== null && reportable.includes(picked) ? picked : (reportable[0] ?? null)

  async function act(run: () => Promise<void>) {
    setBusy(true)
    setError(null)
    try {
      await run()
      series.reload()
      await onSettled()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  function submit(e: FormEvent) {
    e.preventDefault()
    if (current === null) return
    const x = Number(a)
    const y = Number(b)
    if (!Number.isInteger(x) || !Number.isInteger(y) || a === '' || b === '') {
      setError('Enter a whole-number score for each side')
      return
    }
    void act(async () => {
      await reportGame(matchId, current, x, y)
      setA('')
      setB('')
      setPicked(null)
    })
  }

  return (
    <section className="pc-card mr-card" aria-labelledby="mr-series-h">
      <div className="pc-card-head">
        <h2 id="mr-series-h">Score reporting</h2>
        <span className="muted">Best of {d.bestOf} &middot; {nameA} {winsA}&ndash;{winsB} {nameB}</span>
      </div>

      <ul className="mr-games">
        {nums.map((n) => {
          const g = byNo.get(n)
          return (
            <li key={n}>
              <span className="mr-game-no">Game {n}</span>
              <span className="mr-game-score num">{g ? `${g.a} \u2013 ${g.b}` : '\u2014'}</span>
              <span className={'badge ' + (g?.confirmed ? 'badge-success' : g ? 'badge-neutral' : 'badge-neutral')}>
                {g ? (g.confirmed ? 'Confirmed' : `Reported by ${g.by}`) : 'Not played'}
              </span>
              {g?.canConfirm && (
                <button type="button" className="btn-primary" disabled={busy} onClick={() => void act(() => confirmGame(matchId, n))}>
                  Confirm
                </button>
              )}
            </li>
          )
        })}
      </ul>

      {d.canReport && current !== null ? (
        <form className="mr-score-form" onSubmit={submit}>
          {reportable.length > 1 && (
            <label>
              Game
              <select value={current} onChange={(e) => setPicked(Number(e.target.value))}>
                {reportable.map((n) => (
                  <option key={n} value={n}>Game {n}</option>
                ))}
              </select>
            </label>
          )}
          <label>
            {nameA}
            <input inputMode="numeric" value={a} onChange={(e) => setA(e.target.value.replace(/[^0-9]/g, ''))} maxLength={3} />
          </label>
          <label>
            {nameB}
            <input inputMode="numeric" value={b} onChange={(e) => setB(e.target.value.replace(/[^0-9]/g, ''))} maxLength={3} />
          </label>
          <button type="submit" className="btn-primary" disabled={busy}>
            {d.staff ? `Record game ${current}` : `Report game ${current}`}
          </button>
        </form>
      ) : (
        <p className="muted">
          {d.games.length === 0 ? 'Scores open once the match starts, and captains or staff report them here.' : 'Waiting for the next game or the final result.'}
        </p>
      )}
      <p className="muted mr-series-hint">
        A captain reports a score and the other captain confirms it. Reporting different numbers disputes it, and the
        organizer or a referee can record any game directly. The match result is recorded when one side wins the
        majority of games.
      </p>

      {isOwner && (
        <label className="mr-series-length">
          Series length
          <select
            value={d.bestOf}
            disabled={busy}
            onChange={(e) => void act(() => setSeriesLength(tournamentId, Number(e.target.value)))}
          >
            <option value={1}>Best of 1</option>
            <option value={3}>Best of 3</option>
            <option value={5}>Best of 5</option>
          </select>
        </label>
      )}
      {error && <p role="alert" className="form-error">{error}</p>}
    </section>
  )
}