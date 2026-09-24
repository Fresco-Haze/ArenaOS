import { useState } from 'react'
import type { FormEvent } from 'react'
import { useNavigate } from 'react-router'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import { createTournament } from '../lib/tournamentActions'

type Field = 'name' | 'organizer' | 'maxParticipants'

function fieldOf(err: ApiError): Field | null {
  const d = err.details
  if (d && typeof d === 'object' && 'field' in d && typeof d.field === 'string') {
    return d.field as Field
  }
  return null
}

export default function CreateTournamentPage() {
  const { user } = useAuth()
  const navigate = useNavigate()

  const [name, setName] = useState('')
  const [visibility, setVisibility] = useState<'Public' | 'Private'>('Public')
  const [maxParticipants, setMaxParticipants] = useState('8')
  const [fieldErrors, setFieldErrors] = useState<Partial<Record<Field, string>>>({})
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // ProtectedRoute guarantees this, but keep TypeScript honest.
  if (!user) return null

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setFieldErrors({})

    const parsedMax = Number(maxParticipants)
    if (!Number.isFinite(parsedMax)) {
      setFieldErrors({ maxParticipants: 'Enter a whole number' })
      return
    }

    setBusy(true)
    try {
      const res = await createTournament({
        name,
        organizer: user.username,
        visibility,
        maxParticipants: parsedMax,
      })
      navigate(`/tournaments/${res.tournamentId}`)
    } catch (err) {
      setBusy(false)
      if (err instanceof ApiError) {
        const field = fieldOf(err)
        if (field) setFieldErrors({ [field]: err.message })
        else setError(err.message)
      } else {
        setError('Could not reach the server')
      }
    }
  }

  return (
    <>
      <h1>Create tournament</h1>
      <form onSubmit={onSubmit} className="form">
        <label>
          Name
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            autoFocus
            required
          />
          {fieldErrors.name && (
            <span role="alert" className="form-error">{fieldErrors.name}</span>
          )}
        </label>

        <label>
          Organizer
          <input value={user.username} disabled />
        </label>
        {fieldErrors.organizer && (
          <span role="alert" className="form-error">{fieldErrors.organizer}</span>
        )}

        <fieldset>
          <legend>Visibility</legend>
          <label>
            <input
              type="radio"
              name="visibility"
              checked={visibility === 'Public'}
              onChange={() => setVisibility('Public')}
            />
            Public
          </label>
          <label>
            <input
              type="radio"
              name="visibility"
              checked={visibility === 'Private'}
              onChange={() => setVisibility('Private')}
            />
            Private
          </label>
        </fieldset>

        <label>
          Maximum participants
          <input
            type="number"
            min={2}
            value={maxParticipants}
            onChange={(e) => setMaxParticipants(e.target.value)}
            required
          />
          {fieldErrors.maxParticipants && (
            <span role="alert" className="form-error">{fieldErrors.maxParticipants}</span>
          )}
        </label>

        {error && <p role="alert" className="form-error">{error}</p>}
        <button type="submit" disabled={busy}>
          {busy ? 'Creating' : 'Create tournament'}
        </button>
      </form>
    </>
  )
}