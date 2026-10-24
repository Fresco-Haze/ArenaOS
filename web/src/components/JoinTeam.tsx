import { useState } from 'react'
import { Link } from 'react-router'
import { ApiError } from '../api'
import { useApi } from '../hooks/useApi'
import { joinTeam } from '../lib/tournamentActions'
import { TeamList } from '../model'
import type { Tournament } from '../model'

export default function JoinTeam({
  tournament: t,
  onDone,
}: {
  tournament: Tournament
  onDone: () => Promise<void>
}) {
  const mine = useApi('/me/teams', TeamList)
  const [pick, setPick] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const teams = mine.data ? mine.data.teams : null
  const chosen = pick || teams?.[0]?.name || ''

  async function register() {
    setBusy(true)
    setError(null)
    try {
      await joinTeam(t.tournamentId, chosen)
      await onDone()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  if (mine.error) return <p role="alert" className="form-error tp-join">{mine.error}</p>
  if (teams === null) return <p className="muted tp-join">Loading your teams</p>
  if (teams.length === 0) {
    return (
      <p className="muted tp-join">
        You have no teams yet. <Link to="/teams/new">Create a team</Link> to register it here.
      </p>
    )
  }

  return (
    <div className="tp-join">
      <label>
        Register one of your teams
        <select value={chosen} onChange={(e) => setPick(e.target.value)} disabled={busy}>
          {teams.map((x) => (
            <option key={x.name} value={x.name}>{x.name}</option>
          ))}
        </select>
      </label>
      <button className="btn-primary" onClick={() => void register()} disabled={busy || chosen === ''}>
        {busy ? 'Registering' : 'Register team'}
      </button>
      {error && <p role="alert" className="form-error">{error}</p>}
    </div>
  )
}