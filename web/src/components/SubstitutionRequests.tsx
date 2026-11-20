import { useState } from 'react'
import { ApiError } from '../api'
import { useStickyApi } from '../hooks/useStickyApi'
import { decideSubstitution } from '../lib/teamActions'
import { SubstitutionList } from '../model'

const CHIP = { Pending: 'badge-neutral', Approved: 'badge-success', Declined: 'badge-danger' } as const

// Only the organizer and referees can load this; for everyone else the request is refused and this renders nothing.
export default function SubstitutionRequests({ tournamentId }: { tournamentId: number }) {
  const subs = useStickyApi(`/tournaments/${tournamentId}/substitutions`, SubstitutionList)
  const [busy, setBusy] = useState<number | null>(null)
  const [error, setError] = useState<string | null>(null)

  if (!subs.data) return null
  const list = subs.data.requests

  async function decide(id: number, approve: boolean) {
    setBusy(id)
    setError(null)
    try {
      await decideSubstitution(tournamentId, id, approve)
      subs.reload()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className="pc-card mr-card" aria-labelledby="mr-subs-h">
      <h2 id="mr-subs-h" className="pc-card-head">Substitution requests</h2>
      {list.length === 0 ? (
        <p className="muted">No requests. Team owners ask here to swap a player once rosters are locked.</p>
      ) : (
        <ul className="mr-subs">
          {list.map((r) => (
            <li key={r.id}>
              <div>
                <strong>{r.team}</strong>: {r.out} &rarr; {r.incoming}
                <span className="muted"> &middot; requested by {r.by}</span>
              </div>
              {r.status === 'Pending' ? (
                <div className="mr-subs-actions">
                  <button type="button" className="btn-primary" disabled={busy === r.id} onClick={() => void decide(r.id, true)}>
                    Approve
                  </button>
                  <button type="button" disabled={busy === r.id} onClick={() => void decide(r.id, false)}>
                    Decline
                  </button>
                </div>
              ) : (
                <span className={'badge ' + CHIP[r.status]}>{r.status}</span>
              )}
            </li>
          ))}
        </ul>
      )}
      {error && <p role="alert" className="form-error">{error}</p>}
    </section>
  )
}