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
  const [format, setFormat] = useState<'SingleElimination' | 'DoubleElimination'>('SingleElimination')
  const [participantMode, setParticipantMode] = useState<'IndividualOnly' | 'SquadOnly'>('IndividualOnly')

  // ProtectedRoute guarantees this, but keep TypeScript honest.
  if (!user) return null
  const username = user.username

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
        organizer: username,
        visibility,
        maxParticipants: parsedMax,
        thirdPlaceMatch: format === 'SingleElimination',
        format,
        participantMode,
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
          <legend>Format</legend>
          <label>
            <input
              type="radio"
              name="format"
              checked={format === 'SingleElimination'}
              onChange={() => setFormat('SingleElimination')}
            />
            Single elimination
          </label>
          <label>
            <input
              type="radio"
              name="format"
              checked={format === 'DoubleElimination'}
              onChange={() => setFormat('DoubleElimination')}
            />
            Double elimination
          </label>
          <p className="muted">
            {format === 'DoubleElimination'
              ? 'A first loss sends you to the losers bracket, so everyone plays at least twice.'
              : 'One loss and you are out.'}
          </p>
        </fieldset>
        <fieldset>
          <legend>Who is competing?</legend>
          <label>
            <input
              type="radio"
              name="participantMode"
              checked={participantMode === 'IndividualOnly'}
              onChange={() => setParticipantMode('IndividualOnly')}
            />
            Individual players
          </label>
          <label>
            <input
              type="radio"
              name="participantMode"
              checked={participantMode === 'SquadOnly'}
              onChange={() => setParticipantMode('SquadOnly')}
            />
            Teams
          </label>
          <p className="muted">Can't be changed after the tournament is created.</p>
        </fieldset>
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
        <p className="muted">
          {format === 'SingleElimination'
            ? `A third-place match is always played, so 1st to 4th are decided (needs 4 or more ${participantMode === 'SquadOnly' ? 'teams' : 'players'}).`
            : 'Double elimination decides the top four by itself.'}
        </p>

        {error && <p role="alert" className="form-error">{error}</p>}
        <button type="submit" disabled={busy}>
          {busy ? 'Creating' : 'Create tournament'}
        </button>
      </form>
    </>
  )
}