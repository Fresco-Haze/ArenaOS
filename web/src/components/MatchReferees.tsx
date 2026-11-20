import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import { useStickyApi } from '../hooks/useStickyApi'
import { addReferee, removeReferee } from '../lib/matchRoomActions'
import { RefereeList } from '../model'

// Referees can set lobby codes and see and upload evidence. The organizer manages the list.
export default function MatchReferees({
  tournamentId,
  organizer,
  isOwner,
}: {
  tournamentId: number
  organizer: string
  isOwner: boolean
}) {
  const refs = useStickyApi(`/tournaments/${tournamentId}/referees`, RefereeList)
  const [who, setWho] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function add(e: FormEvent) {
    e.preventDefault()
    const name = who.trim()
    if (name === '') return
    setBusy(true)
    setError(null)
    try {
      await addReferee(tournamentId, name)
      setWho('')
      refs.reload()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  async function remove(userId: number) {
    setError(null)
    try {
      await removeReferee(tournamentId, userId)
      refs.reload()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    }
  }

  const list = refs.data ? refs.data.referees : []

  return (
    <section className="pc-card mr-card" aria-labelledby="mr-ref-h">
      <h2 id="mr-ref-h" className="pc-card-head">Referees</h2>
      <ul className="mr-refs">
        <li className="tm-chip">{organizer} <span className="muted">organizer</span></li>
        {list.map((r) => (
          <li key={r.userId} className="tm-chip">
            {r.username}
            {isOwner && (
              <button type="button" aria-label={`Remove referee ${r.username}`} onClick={() => void remove(r.userId)}>
                &times;
              </button>
            )}
          </li>
        ))}
      </ul>
      {isOwner && (
        <form className="mr-row" onSubmit={(e) => void add(e)}>
          <label className="sr-only" htmlFor="mr-ref-input">Add a referee</label>
          <input
            id="mr-ref-input"
            value={who}
            onChange={(e) => setWho(e.target.value)}
            placeholder="Add a referee by username"
            autoComplete="off"
          />
          <button type="submit" disabled={busy || who.trim() === ''}>Add referee</button>
        </form>
      )}
      {error && <p role="alert" className="form-error">{error}</p>}
    </section>
  )
}