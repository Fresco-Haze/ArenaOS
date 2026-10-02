import { useState } from 'react'
import type { FormEvent } from 'react'
import { useNavigate } from 'react-router'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import { createTeam } from '../lib/tournamentActions'

export default function CreateTeamPage() {
  const { user } = useAuth()
  const navigate = useNavigate()

  const [name, setName] = useState('')
  const [captain, setCaptain] = useState('')
  const [membersText, setMembersText] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  if (!user) return null

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)

    const members = membersText
      .split(',')
      .map((m) => m.trim())
      .filter((m) => m.length > 0)

    setBusy(true)
    try {
      const team = await createTeam({ name, captain, members })
      navigate(-1)
      // navigate(-1) returns to wherever the "Create a team" link was
      // clicked from, so the organizer lands back on the registration
      // form with the new team now registerable by name.
      void team
    } catch (err) {
      setBusy(false)
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    }
  }

  return (
    <>
      <h1>Create a team</h1>
      <form onSubmit={onSubmit} className="form">
        <label>
          Team name
          <input value={name} onChange={(e) => setName(e.target.value)} autoFocus required />
        </label>
        <label>
          Captain
          <input value={captain} onChange={(e) => setCaptain(e.target.value)} required />
        </label>
        <label>
          Members
          <input
            value={membersText}
            onChange={(e) => setMembersText(e.target.value)}
            placeholder="Comma-separated names, including the captain"
            required
          />
        </label>
        {error && <p role="alert" className="form-error">{error}</p>}
        <button type="submit" disabled={busy}>
          {busy ? 'Creating' : 'Create team'}
        </button>
      </form>
    </>
  )
}