import { useState } from 'react'
import { Link } from 'react-router'
import { useApi } from '../hooks/useApi'
import { joinTeam } from '../lib/tournamentActions'
import { TeamList } from '../model'
import type { Tournament } from '../model'
import ConfirmDialog from './ConfirmDialog'
import RegisterSummary from './RegisterSummary'

export default function JoinTeam({
  tournament: t,
  onDone,
}: {
  tournament: Tournament
  onDone: () => Promise<void>
}) {
  const mine = useApi('/me/teams', TeamList)
  const [pick, setPick] = useState('')
  const [open, setOpen] = useState(false)

  const teams = mine.data ? mine.data.teams : null
  const chosen = pick || teams?.[0]?.name || ''

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
      <button className="btn-primary" onClick={() => setOpen(true)} disabled={chosen === ''}>
        Register team
      </button>
      <ConfirmDialog
        open={open}
        title="Register your team"
        confirmLabel="Confirm registration"
        className="dialog-wide"
        confirmDisabled={chosen === ''}
        onConfirm={async () => {
          await joinTeam(t.tournamentId, chosen)
          await onDone()
        }}
        onClose={() => setOpen(false)}
      >
        <label className="reg-field">
          Team
          <select value={chosen} onChange={(e) => setPick(e.target.value)}>
            {teams.map((x) => (
              <option key={x.name} value={x.name}>{x.name}</option>
            ))}
          </select>
        </label>
        <RegisterSummary tournament={t} />
      </ConfirmDialog>
    </div>
  )
}