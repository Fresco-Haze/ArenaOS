import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import { inviteToTeam, revokeTeamInvite } from '../lib/teamActions'

// Owner tools on a team card: invite a player by username and revoke pending invites.
export default function TeamInvitePanel({
  teamName,
  pending,
  onChanged,
}: {
  teamName: string
  pending: { userId: number; username: string }[]
  onChanged: () => void
}) {
  const [who, setWho] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function send(e: FormEvent) {
    e.preventDefault()
    const name = who.trim()
    if (name === '') return
    setBusy(true)
    setError(null)
    try {
      await inviteToTeam(teamName, name)
      setWho('')
      onChanged()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  async function revoke(userId: number) {
    setError(null)
    try {
      await revokeTeamInvite(teamName, userId)
      onChanged()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    }
  }

  return (
    <div className="tm-invite-panel">
      <form className="tm-add" onSubmit={(e) => void send(e)}>
        <label className="sr-only" htmlFor={`inv-${teamName}`}>Invite a player to {teamName}</label>
        <input
          id={`inv-${teamName}`}
          value={who}
          onChange={(e) => setWho(e.target.value)}
          placeholder="Invite by username"
          autoComplete="off"
        />
        <button type="submit" disabled={busy || who.trim() === ''}>Invite</button>
      </form>
      {error && <p role="alert" className="form-error">{error}</p>}
      {pending.length > 0 && (
        <ul className="tm-chips" aria-label="Pending invites">
          {pending.map((i) => (
            <li key={i.userId} className="tm-chip">
              {i.username} <span className="muted">pending</span>
              <button type="button" aria-label={`Revoke invite for ${i.username}`} onClick={() => void revoke(i.userId)}>
                &times;
              </button>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}