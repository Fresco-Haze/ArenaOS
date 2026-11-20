import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import { useStickyApi } from '../hooks/useStickyApi'
import { requestSubstitution } from '../lib/teamActions'
import { SubstitutionState } from '../model'

const CHIP = { Pending: 'badge-neutral', Approved: 'badge-success', Declined: 'badge-danger' } as const

// Owner-only. Shows the roster lock and lets the owner ask staff to swap one member for another.
export default function TeamSubstitutions({
  team,
  captain,
  members,
}: {
  team: string
  captain: string
  members: string[]
}) {
  const subs = useStickyApi(`/teams/${encodeURIComponent(team)}/substitutions`, SubstitutionState)
  const [out, setOut] = useState('')
  const [who, setWho] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const d = subs.data
  if (!d) return null
  if (!d.locked && d.requests.length === 0) return null

  const bench = members.filter((m) => m.toLowerCase() !== captain.toLowerCase())
  const chosen = out !== '' ? out : (bench[0] ?? '')
  const locked = d.locked

  async function send(e: FormEvent) {
    e.preventDefault()
    if (!locked || chosen === '' || who.trim() === '') return
    setBusy(true)
    setError(null)
    try {
      await requestSubstitution(team, { tournamentId: locked.tournamentId, out: chosen, incoming: who.trim() })
      setWho('')
      subs.reload()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="tm-subs">
      {locked && (
        <p className="tm-lock">
          <strong>Roster locked</strong> while this team plays in {locked.name}. New members need a substitution that the
          organizer or a referee approves.
        </p>
      )}
      {locked && bench.length > 0 && (
        <form className="tm-sub-form" onSubmit={(e) => void send(e)}>
          <label className="sr-only" htmlFor={`sub-out-${team}`}>Member going out</label>
          <select id={`sub-out-${team}`} value={chosen} onChange={(e) => setOut(e.target.value)}>
            {bench.map((m) => (
              <option key={m} value={m}>{m}</option>
            ))}
          </select>
          <span aria-hidden="true" className="muted">&rarr;</span>
          <label className="sr-only" htmlFor={`sub-in-${team}`}>Username coming in</label>
          <input
            id={`sub-in-${team}`}
            value={who}
            onChange={(e) => setWho(e.target.value)}
            placeholder="Replacement username"
            autoComplete="off"
          />
          <button type="submit" disabled={busy || who.trim() === ''}>Request substitution</button>
        </form>
      )}
      {error && <p role="alert" className="form-error">{error}</p>}
      {d.requests.length > 0 && (
        <ul className="tm-sub-list" aria-label="Substitution requests">
          {d.requests.slice(0, 5).map((r) => (
            <li key={r.id}>
              <span><strong>{r.out}</strong> &rarr; <strong>{r.incoming}</strong></span>
              <span className={'badge ' + CHIP[r.status]}>{r.status}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}