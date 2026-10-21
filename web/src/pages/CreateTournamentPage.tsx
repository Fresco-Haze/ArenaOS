import { useState } from 'react'
import type { FormEvent } from 'react'
import { useNavigate } from 'react-router'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import { createTournament } from '../lib/tournamentActions'
import DetailsFields from '../components/DetailsFields'
import { emptyDetails, toPayload } from '../lib/details'
import type { DetailsValues } from '../lib/details'

type Field = 'name' | 'organizer' | 'maxParticipants' | 'prize'
type Format = 'SingleElimination' | 'DoubleElimination' | 'RoundRobin'

function fieldOf(err: ApiError): Field | null {
  const d = err.details
  if (d && typeof d === 'object' && 'field' in d && typeof d.field === 'string') {
    return d.field as Field
  }
  return null
}

function matchCountLine(format: Format, n: number, unit: string): string | null {
  if (!Number.isInteger(n) || n < 2 || n > 512) return null
  if (format === 'SingleElimination') {
    if (n < 4) return null
    return `With ${n} ${unit}: ${n} matches in total, including the third-place match.`
  }
  if (format === 'DoubleElimination') {
    return `With ${n} ${unit}: ${2 * n - 2} to ${2 * n - 1} matches in total (one extra only if a reset match is needed).`
  }
  return `With ${n} ${unit}: ${(n * (n - 1)) / 2} matches in total.`
}

const FORMAT_HINT: Record<Format, string> = {
  SingleElimination: 'One loss and you are out.',
  DoubleElimination:
    'A first loss sends you to the losers bracket, so everyone plays at least twice. If the losers-bracket winner wins the grand final, one extra match settles it.',
  RoundRobin:
    'Everyone plays everyone once. Points decide the table: 3 for a win, 1 for a draw. Ties go to goal difference, then goals scored.',
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
  const [format, setFormat] = useState<Format>('SingleElimination')
  const [participantMode, setParticipantMode] = useState<'IndividualOnly' | 'SquadOnly'>('IndividualOnly')
  const [details, setDetails] = useState<DetailsValues>(emptyDetails)

  // ProtectedRoute guarantees this, but keep TypeScript honest.
  if (!user) return null
  const username = user.username
  const unit = participantMode === 'SquadOnly' ? 'teams' : 'players'
  const matchLine = matchCountLine(format, Number(maxParticipants), unit)

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
        ...toPayload(details),
      })
      navigate(`/tournaments/${res.tournamentId}`)
    } catch (err) {
      setBusy(false)
      if (err instanceof ApiError) {
        const field = fieldOf(err)
        if (field && field !== 'organizer') setFieldErrors({ [field]: err.message })
        else setError(err.message)
      } else {
        setError('Could not reach the server')
      }
    }
  }

  return (
    <>
      <h1>Create tournament</h1>
      <form onSubmit={onSubmit} className="form create-form">
        <h2 className="form-section-title">Basic information</h2>

        <label>
          <span>Tournament name <span className="req" aria-hidden="true">*</span></span>
          <input
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. Rising Stars Cup"
            autoFocus
            required
          />
          {fieldErrors.name && (
            <span role="alert" className="form-error">{fieldErrors.name}</span>
          )}
        </label>

        <DetailsFields
          values={details}
          onChange={setDetails}
          afterGame={
            <>
              <label>
                Format
                <select value={format} onChange={(e) => setFormat(e.target.value as Format)}>
                  <option value="SingleElimination">Single elimination</option>
                  <option value="DoubleElimination">Double elimination</option>
                  <option value="RoundRobin">Round robin</option>
                </select>
              </label>
              <p className="muted">{FORMAT_HINT[format]}</p>
            </>
          }
        />
        {fieldErrors.prize && (
          <span role="alert" className="form-error">{fieldErrors.prize}</span>
        )}

        <h2 className="form-section-title">Participants and visibility</h2>

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
            ? `A third-place match is always played, so 1st to 4th are decided (needs 4 or more ${unit}).`
            : format === 'DoubleElimination'
            ? 'Double elimination decides the top four by itself.'
            : 'Round robin ranks everyone by points, then goal difference, then goals scored.'}
        </p>
        {matchLine && <p className="muted">{matchLine}</p>}

        {error && <p role="alert" className="form-error">{error}</p>}
        <div className="form-actions form-actions-full">
          <button type="submit" className="btn-primary" disabled={busy}>
            {busy ? 'Creating' : 'Create tournament'}
          </button>
          <button type="button" onClick={() => navigate('/me')}>Cancel</button>
        </div>
      </form>
    </>
  )
}