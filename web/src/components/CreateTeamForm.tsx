import { useEffect, useState } from 'react'
import type { ChangeEvent, FormEvent, KeyboardEvent } from 'react'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import { resizeToJpeg } from '../lib/avatarImage'
import { createTeam } from '../lib/tournamentActions'
import { saveTeamProfile, uploadTeamLogo } from '../lib/teamActions'
import { EMPTY_PROFILE } from '../lib/teamProfile'
import type { ProfileDraft } from '../lib/teamProfile'
import TeamCrest from './TeamCrest'
import TeamProfileFields from './TeamProfileFields'

export default function CreateTeamForm({ onDone, onCancel }: { onDone: () => void; onCancel?: () => void }) {
  const { user } = useAuth()

  const [name, setName] = useState('')
  const [captain, setCaptain] = useState(user?.username ?? '')
  const [members, setMembers] = useState<string[]>([])
  const [draft, setDraft] = useState('')
  const [profile, setProfile] = useState<ProfileDraft>(EMPTY_PROFILE)
  const [logo, setLogo] = useState<Blob | null>(null)
  const [logoUrl, setLogoUrl] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => () => {
    if (logoUrl) URL.revokeObjectURL(logoUrl)
  }, [logoUrl])

  if (!user) return null

  async function onLogo(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    e.target.value = ''
    if (!file) return
    try {
      const blob = await resizeToJpeg(file, 256)
      setLogo(blob)
      setLogoUrl(URL.createObjectURL(blob))
    } catch {
      setError('That image could not be read')
    }
  }

  function addMember() {
    const m = draft.trim()
    if (m === '') return
    if (!members.some((x) => x.toLowerCase() === m.toLowerCase())) setMembers([...members, m])
    setDraft('')
  }

  function onDraftKey(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key === 'Enter' || e.key === ',') {
      e.preventDefault()
      addMember()
    }
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    const cap = captain.trim()
    const teamName = name.trim()
    if (profile.tag !== '' && profile.tag.length < 3) {
      setError('The tag needs 3 or 4 characters, or leave it empty')
      return
    }
    const all = [cap, ...members].filter(
      (m, i, a) => m !== '' && a.findIndex((x) => x.toLowerCase() === m.toLowerCase()) === i,
    )
    setBusy(true)
    try {
      await createTeam({ name: teamName, captain: cap, members: all })
      try {
        await saveTeamProfile(teamName, profile)
      } catch {
        /* the team exists; details can be added from its card */
      }
      if (logo) {
        try {
          await uploadTeamLogo(teamName, logo)
        } catch {
          /* the logo can be added later from the team card */
        }
      }
      onDone()
    } catch (err) {
      setBusy(false)
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    }
  }

  const total = new Set([captain.trim().toLowerCase(), ...members.map((m) => m.toLowerCase())].filter(Boolean)).size

  return (
    <form onSubmit={onSubmit} className="tm-form">
      <section className="tm-preview" aria-label="Team preview">
        {logoUrl ? (
          <img className="crest crest-img" src={logoUrl} width={72} height={72} alt="Chosen logo" />
        ) : (
          <TeamCrest name={name.trim() || '?'} size={72} />
        )}
        <div>
          <p className="tm-preview-name">
            {profile.tag && <span className="tm-tag">[{profile.tag}]</span>} {name.trim() || 'Your team name'}
          </p>
          <p className="muted">{total} {total === 1 ? 'member' : 'members'}</p>
          <div className="tm-actions">
            <label className="tm-file">
              {logoUrl ? 'Change logo' : 'Upload logo'}
              <input type="file" accept="image/*" className="sr-only" onChange={(e) => void onLogo(e)} />
            </label>
            {logoUrl && (
              <button type="button" onClick={() => { setLogo(null); setLogoUrl(null) }}>Remove</button>
            )}
          </div>
        </div>
      </section>

      <label>
        Team name
        <input value={name} onChange={(e) => setName(e.target.value)} required />
      </label>
      <label>
        Captain
        <input value={captain} onChange={(e) => setCaptain(e.target.value)} required />
      </label>

      <TeamProfileFields value={profile} onChange={setProfile} idPrefix="new-team" />

      <div className="tm-members-field">
        <label htmlFor="tm-member-input">Add members</label>
        <div className="tm-add">
          <input
            id="tm-member-input"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onDraftKey}
            placeholder="Player username, then Enter"
            autoComplete="off"
          />
          <button type="button" onClick={addMember} disabled={draft.trim() === ''}>Add</button>
        </div>
        {members.length > 0 && (
          <ul className="tm-chips" aria-label="Members to add">
            {members.map((m) => (
              <li key={m} className="tm-chip">
                {m}
                <button type="button" aria-label={`Remove ${m}`} onClick={() => setMembers(members.filter((x) => x !== m))}>
                  &times;
                </button>
              </li>
            ))}
          </ul>
        )}
        <p className="muted">The captain is added to the roster automatically. To invite a registered player, use the invite box on the team once it exists.</p>
      </div>

      {error && <p role="alert" className="form-error">{error}</p>}
      <div className="form-actions">
        <button type="submit" className="btn-primary" disabled={busy}>
          {busy ? 'Creating' : 'Create team'}
        </button>
        {onCancel && <button type="button" onClick={onCancel}>Cancel</button>}
      </div>
    </form>
  )
}