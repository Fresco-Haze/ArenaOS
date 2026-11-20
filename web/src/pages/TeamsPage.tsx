import { useState } from 'react'
import type { ChangeEvent } from 'react'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import { useApi } from '../hooks/useApi'
import { resizeToJpeg } from '../lib/avatarImage'
import { acceptTeamInvite, declineTeamInvite, removeTeamLogo, uploadTeamLogo } from '../lib/teamActions'
import { MyTeamInviteList, TeamList } from '../model'
import CreateTeamForm from '../components/CreateTeamForm'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'
import TeamCard from '../components/TeamCard'
import TeamCrest from '../components/TeamCrest'

export default function TeamsPage() {
  const { user } = useAuth()
  const teams = useApi('/me/teams', TeamList)
  const joined = useApi('/me/joined-teams', TeamList)
  const invites = useApi('/me/team-invites', MyTeamInviteList)
  const [versions, setVersions] = useState<Record<string, number>>({})
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [formKey, setFormKey] = useState(0)

  const createLink = (label: string) => (
    <a href="#create-team" className="button-link btn-primary">{label}</a>
  )
  const bump = (name: string) => setVersions((v) => ({ ...v, [name]: (v[name] ?? 0) + 1 }))
  const fail = (err: unknown, fallback: string) =>
    setError(err instanceof ApiError ? err.message : fallback)

  async function onPick(name: string, e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    e.target.value = ''
    if (!file) return
    setBusy(name)
    setError(null)
    try {
      await uploadTeamLogo(name, await resizeToJpeg(file, 256))
      bump(name)
    } catch (err) {
      fail(err, 'Could not upload the logo')
    } finally {
      setBusy(null)
    }
  }

  async function onRemove(name: string) {
    setBusy(name)
    setError(null)
    try {
      await removeTeamLogo(name)
      bump(name)
    } catch (err) {
      fail(err, 'Could not remove the logo')
    } finally {
      setBusy(null)
    }
  }

  async function respond(team: string, accept: boolean) {
    setBusy('invite:' + team)
    setError(null)
    try {
      if (accept) await acceptTeamInvite(team)
      else await declineTeamInvite(team)
      invites.retry()
      joined.retry()
    } catch (err) {
      fail(err, 'Could not answer the invite')
    } finally {
      setBusy(null)
    }
  }

  const invited = invites.data ? invites.data.invites : []
  const joinedTeams = joined.data ? joined.data.teams : []
  const mine = teams.data ? teams.data.teams : []

  return (
    <div className="tm">
      <PageHeader title="Team management" actions={createLink('New team')} />
      <p className="muted tm-sub">Run your rosters, handle invites and spin up new squads.</p>
      {error && <p role="alert" className="form-error">{error}</p>}

      {teams.error ? (
        <ErrorBanner message={teams.error} onRetry={teams.retry} />
      ) : !teams.data ? (
        <LoadingBlock label="Loading teams" />
      ) : mine.length === 0 ? (
        <EmptyState title="No teams yet" action={createLink('Create your first team')}>
          Teams you create appear here, and you can register them in squad tournaments.
        </EmptyState>
      ) : (
        <section aria-labelledby="tm-mine-h">
          <h2 id="tm-mine-h" className="tm-section-title">My teams <span className="tm-count-chip">{mine.length}</span></h2>
          <ul className="tm-grid">
            {mine.map((t) => (
              <TeamCard
                key={t.name}
                team={t}
                isCaptain={user ? t.captain === user.username : false}
                version={versions[t.name] ?? 0}
                busy={busy === t.name}
                onPick={(e) => void onPick(t.name, e)}
                onRemove={() => void onRemove(t.name)}
              />
            ))}
          </ul>
        </section>
      )}

      <section className="tm-invites" aria-labelledby="tm-inv-h">
        <h2 id="tm-inv-h" className="tm-section-title">Team invites <span className="tm-count-chip">{invited.length}</span></h2>
        {invited.length === 0 ? (
          <p className="muted">No pending invites. When a team owner invites you, it shows up here.</p>
        ) : (
          <ul className="tm-invite-list">
            {invited.map((i) => (
              <li key={i.team} className="tm-invite">
                <TeamCrest name={i.team} size={40} team />
                <span className="tm-invite-text">
                  <strong>{i.team}</strong>
                  <span className="muted"> invited by {i.invitedBy}</span>
                </span>
                <button type="button" className="btn-primary" disabled={busy === 'invite:' + i.team} onClick={() => void respond(i.team, true)}>
                  Accept
                </button>
                <button type="button" disabled={busy === 'invite:' + i.team} onClick={() => void respond(i.team, false)}>
                  Decline
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>

      {joinedTeams.length > 0 && (
        <section aria-labelledby="tm-joined-h" className="tm-joined">
          <h2 id="tm-joined-h" className="tm-section-title">Teams you&rsquo;re on <span className="tm-count-chip">{joinedTeams.length}</span></h2>
          <ul className="tm-grid">
            {joinedTeams.map((t) => (
              <li key={t.name} className="tm-card">
                <div className="tm-id">
                  <TeamCrest name={t.name} size={48} team />
                  <div>
                    <h3>{t.name}</h3>
                    <p className="muted">Captain {t.captain}</p>
                  </div>
                  <span className="badge badge-neutral">Member</span>
                </div>
                <p className="tm-count"><span className="num">{t.members.length}</span> <span className="muted">members</span></p>
              </li>
            ))}
          </ul>
        </section>
      )}

      <section id="create-team" className="tm-create-section" aria-labelledby="tm-create-h">
        <h2 id="tm-create-h">Create new team</h2>
        <CreateTeamForm key={formKey} onDone={() => { setFormKey((k) => k + 1); teams.retry() }} />
      </section>
    </div>
  )
}