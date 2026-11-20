import { useState } from 'react'
import type { ChangeEvent } from 'react'
import { ApiError } from '../api'
import { useStickyApi } from '../hooks/useStickyApi'
import { saveTeamProfile } from '../lib/teamActions'
import { teamHue } from '../lib/teamHue'
import { RECRUITMENT_LABEL } from '../lib/teamProfile'
import type { ProfileDraft } from '../lib/teamProfile'
import { TeamInvitePendingList, TeamProfileView } from '../model'
import type { Team } from '../model'
import TeamCrest from './TeamCrest'
import TeamInvitePanel from './TeamInvitePanel'
import TeamProfileFields from './TeamProfileFields'
import TeamSubstitutions from './TeamSubstitutions'

function initials(name: string): string {
  return name.replace(/[^a-zA-Z0-9]/g, '').slice(0, 2).toUpperCase() || '?'
}

export default function TeamCard({
  team,
  isCaptain,
  version,
  busy,
  onPick,
  onRemove,
}: {
  team: Team
  isCaptain: boolean
  version: number
  busy: boolean
  onPick: (e: ChangeEvent<HTMLInputElement>) => void
  onRemove: () => void
}) {
  const invites = useStickyApi(`/teams/${encodeURIComponent(team.name)}/invites`, TeamInvitePendingList)
  const profile = useStickyApi(`/teams/${encodeURIComponent(team.name)}/profile`, TeamProfileView)
  const [draft, setDraft] = useState<ProfileDraft | null>(null)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const pending = invites.data ? invites.data.invites : []
  const p = profile.data
  const hue = teamHue(team.name)
  const shown = team.members.slice(0, 5)
  const extra = team.members.length - shown.length
  const editing: ProfileDraft = draft ?? {
    tag: p?.tag ?? '',
    game: p?.game ?? '',
    region: p?.region ?? '',
    recruitment: p?.recruitment ?? 'InviteOnly',
  }

  async function save() {
    if (editing.tag !== '' && editing.tag.length < 3) {
      setError('The tag needs 3 or 4 characters, or leave it empty')
      return
    }
    setSaving(true)
    setError(null)
    try {
      await saveTeamProfile(team.name, editing)
      setDraft(null)
      profile.reload()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setSaving(false)
    }
  }

  return (
    <li className="tm-card tm-card-v2">
      <div
        className="tm-banner"
        style={{ background: `linear-gradient(135deg, hsl(${hue} 70% 14%), hsl(${hue} 70% 34%))` }}
      >
        <span className="tm-role">{isCaptain ? 'Captain' : 'Member'}</span>
        {p && p.game !== '' && <span className="tm-role">{p.game}</span>}
      </div>
      <div className="tm-body">
        <div className="tm-id tm-id-raised">
          <TeamCrest name={team.name} size={56} team version={version} />
          <div>
            <h2>
              {p && p.tag !== '' && <span className="tm-tag">[{p.tag}]</span>} {team.name}
            </h2>
            <p className="muted">
              Captain {team.captain}
              {p && p.region !== '' && <> &middot; {p.region}</>}
            </p>
          </div>
        </div>

        <dl className="tm-stats tm-stats-3">
          <div>
            <dt>Roster</dt>
            <dd className="num">{team.members.length}</dd>
          </div>
          <div>
            <dt>Record</dt>
            <dd className="num">
              <span className="tm-win">{p ? p.wins : 0}</span>-<span className="tm-loss">{p ? p.losses : 0}</span>
            </dd>
          </div>
          <div>
            <dt>Invites</dt>
            <dd className="num">{pending.length} <span className="muted">open</span></dd>
          </div>
        </dl>

        <div className="tm-avatars" aria-label={`${team.members.length} members`}>
          {shown.map((m) => (
            <span
              key={m}
              className="tm-avatar"
              title={m}
              style={{ background: `hsl(${teamHue(m)} 60% 32%)` }}
            >
              {initials(m)}
            </span>
          ))}
          {extra > 0 && <span className="tm-avatar tm-avatar-more">+{extra}</span>}
          {p && <span className="tm-recruit-chip">{RECRUITMENT_LABEL[p.recruitment]}</span>}
        </div>

        <details className="tm-members-detail">
          <summary>Members</summary>
          <ul className="tm-members">
            {team.members.map((m) => (
              <li key={m}>{m}</li>
            ))}
          </ul>
        </details>

        <details className="tm-members-detail">
          <summary>Team settings</summary>
          <TeamProfileFields value={editing} onChange={setDraft} idPrefix={`team-${team.name}`} />
          {error && <p role="alert" className="form-error">{error}</p>}
          <button type="button" className="btn-primary tm-save" onClick={() => void save()} disabled={saving || draft === null}>
            {saving ? 'Saving' : 'Save details'}
          </button>
        </details>

        <TeamSubstitutions team={team.name} captain={team.captain} members={team.members} />

        <div className="tm-actions">
          <label className="tm-file">
            Change logo
            <input type="file" accept="image/*" className="sr-only" disabled={busy} onChange={onPick} />
          </label>
          <button type="button" onClick={onRemove} disabled={busy}>Remove logo</button>
        </div>

        <TeamInvitePanel teamName={team.name} pending={pending} onChanged={invites.reload} />
      </div>
    </li>
  )
}