import { setRequireApproval as setApprovalOnServer } from '../lib/tournamentActions'
import { useEffect, useMemo, useRef, useState } from 'react'
import type { ChangeEvent, FormEvent } from 'react'
import { useLocation, useNavigate } from 'react-router'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import { bumpBanner } from '../lib/banner'
import { resizeBannerToJpeg } from '../lib/bannerImage'
import { createTournament, uploadBanner } from '../lib/tournamentActions'
import { formatKes } from '../lib/money'
import DetailsFields from '../components/DetailsFields'
import { PLATFORMS, deadlineError, detailsFromTournament, emptyDetails, feeError, prizeError, streamError, toPayload } from '../lib/details'
import type { DetailsValues } from '../lib/details'
import { formatLabel, gameLabel } from '../model'
import type { Tournament } from '../model'

type Format = 'SingleElimination' | 'DoubleElimination' | 'RoundRobin'

const STEPS = ['Basic info', 'Game & format', 'Settings', 'Review'] as const
const LAST = STEPS.length - 1

// Which step owns a field the server complains about (anything else is in Settings).
const FIELD_STEP: Record<string, number> = {
  name: 0, description: 0, game: 1, platform: 1, format: 1, maxParticipants: 1, participantMode: 1, settings: 1,
}

function fieldOf(err: ApiError): string | null {
  const d = err.details
  if (d && typeof d === 'object' && 'field' in d && typeof d.field === 'string') return d.field
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

const LOBBY_HINT = "Everyone plays together. After each round you enter every participant's place and kills, and points decide the standings."

export default function CreateTournamentPage() {
  const { user } = useAuth()
  const navigate = useNavigate()
  // "Duplicate" on a tournament page sends that tournament here. It only fills the starting
  // values. Start time, deadline and banner are left empty on purpose.
  const copyOf = (useLocation().state as { copyOf?: Tournament } | null)?.copyOf ?? null
  const copied = copyOf ? { ...detailsFromTournament(copyOf), start: '', deadline: '' } : null

  const [step, setStep] = useState(0)
  const [name, setName] = useState(copyOf ? copyOf.name + ' (copy)' : '')
  const [visibility, setVisibility] = useState<'Public' | 'Private'>(copyOf?.visibility ?? 'Public')
  const [maxParticipants, setMaxParticipants] = useState(copyOf ? String(copyOf.maxParticipants) : '8')
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({})
  const [stepProblem, setStepProblem] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [format, setFormat] = useState<Format>(copyOf ? copyOf.format : 'SingleElimination')
  const [isLobby, setIsLobby] = useState(copyOf?.kind === 'Lobby')
  const [killPoints, setKillPoints] = useState('1')
  const [placementPoints, setPlacementPoints] = useState('10, 6, 5, 4, 3, 2, 1, 1')
  const [participantMode, setParticipantMode] = useState<'IndividualOnly' | 'SquadOnly'>(copyOf?.participantMode ?? 'IndividualOnly')
  const [requireApproval, setRequireApproval] = useState(copyOf ? copyOf.requireApproval : true)
  const [details, setDetails] = useState<DetailsValues>(copied ?? emptyDetails)
  const [bannerFile, setBannerFile] = useState<File | null>(null)
  const [bannerNote, setBannerNote] = useState<string | null>(null)
  const bannerInput = useRef<HTMLInputElement>(null)
  const bannerPreview = useMemo(() => (bannerFile ? URL.createObjectURL(bannerFile) : null), [bannerFile])
  useEffect(() => () => { if (bannerPreview) URL.revokeObjectURL(bannerPreview) }, [bannerPreview])

  // ProtectedRoute guarantees this, but keep TypeScript honest.
  if (!user) return null
  const username = user.username
  const unit = participantMode === 'SquadOnly' ? 'teams' : 'players'
  const matchLine = isLobby ? null : matchCountLine(format, Number(maxParticipants), unit)

  function stepError(i: number): string | null {
    if (i === 0) return name.trim() === '' ? 'Enter a tournament name.' : null
    if (i === 1) {
      const n = Number(maxParticipants)
      if (!(Number.isInteger(n) && n >= 2)) return 'Maximum participants must be a whole number, at least 2.'
      if (isLobby) {
        const kp = Number(killPoints)
        if (!Number.isInteger(kp) || kp < 0 || kp > 1000) return 'Points per kill must be a whole number from 0 to 1000.'
        if (!/^\s*\d{1,4}\s*(,\s*\d{1,4}\s*){0,99}$/.test(placementPoints)) return 'Placement points must be whole numbers from 0 to 1000, separated by commas.'
      }
      return null
    }
    if (i === 2) return prizeError(details.prize) ?? feeError(details.entryFee) ?? deadlineError(details) ?? streamError(details.streamUrl)
    return null
  }

  function firstBadStep(upTo: number): number {
    for (let i = 0; i < upTo; i++) if (stepError(i) !== null) return i
    return -1
  }

  function goTo(i: number) {
    setStepProblem(null)
    if (i <= step) {
      setStep(i)
      return
    }
    const bad = firstBadStep(i)
    if (bad >= 0) {
      setStep(bad)
      setStepProblem(stepError(bad))
    } else {
      setStep(i)
    }
  }

  function onRemoveBanner() {
    setBannerFile(null)
    setBannerNote(null)
    if (bannerInput.current) bannerInput.current.value = ''
  }

  function onPickBanner(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    setBannerNote(null)
    if (!file) {
      setBannerFile(null)
      return
    }
    if (!file.type.startsWith('image/')) {
      setBannerNote('Choose an image file.')
      e.target.value = ''
      setBannerFile(null)
      return
    }
    if (file.size > 10 * 1024 * 1024) {
      setBannerNote('That image is too large (10 MB at most).')
      e.target.value = ''
      setBannerFile(null)
      return
    }
    setBannerFile(file)
  }

  async function create() {
    const bad = firstBadStep(3)
    if (bad >= 0) {
      setStep(bad)
      setStepProblem(stepError(bad))
      return
    }
    setError(null)
    setFieldErrors({})
    setBusy(true)
    try {
      const res = await createTournament({
        name,
        organizer: username,
        visibility,
        maxParticipants: Number(maxParticipants),
        thirdPlaceMatch: format === 'SingleElimination',
        format,
        participantMode,
        requireApproval: participantMode === 'IndividualOnly' && requireApproval,
        lobby: isLobby ? { killPoints: Number(killPoints), placementPoints } : null,
        ...toPayload(details),
      })
      if (isLobby && participantMode === 'IndividualOnly' && requireApproval) {
        try {
          await setApprovalOnServer(res.tournamentId, true)
        } catch {
          // The lobby exists; the organizer can switch approval on from its page.
        }
      }
      if (bannerFile) {
        try {
          const blob = await resizeBannerToJpeg(bannerFile)
          await uploadBanner(res.tournamentId, blob)
          bumpBanner()
        } catch {
          // The tournament exists; the organizer can retry with "Edit banner" on its page.
        }
      }
      navigate(`/tournaments/${res.tournamentId}`)
    } catch (err) {
      setBusy(false)
      if (err instanceof ApiError) {
        const field = fieldOf(err)
        if (field && field !== 'organizer') {
          setFieldErrors({ [field]: err.message })
          setStep(FIELD_STEP[field] ?? 2)
        } else {
          setError(err.message)
        }
      } else {
        setError('Could not reach the server')
      }
    }
  }

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (step < LAST) {
      goTo(step + 1)
      return
    }
    void create()
  }

  const stepErrors = Object.entries(fieldErrors)
    .filter(([f]) => (FIELD_STEP[f] ?? 2) === step)
    .map(([, m]) => m)
  const p = toPayload(details)
  const platformLabel = PLATFORMS.find((x) => x.value === p.platform)?.label

  return (
    <>
      <h1>Create tournament</h1>
      {copyOf && (
        <p className="muted" role="status">
          Copied from {copyOf.name}. Start time, registration deadline and banner are not copied.
          {copyOf.kind === 'Lobby' && ' Scoring settings are not copied, check them before creating.'}
        </p>
      )}
      <ol className="create-steps" aria-label="Steps">
        {STEPS.map((label, i) => (
          <li key={label}>
            <button
              type="button"
              className="create-step"
              aria-current={i === step ? 'step' : undefined}
              onClick={() => goTo(i)}
            >
              <span className="create-step-num">{i + 1}</span> {label}
            </button>
          </li>
        ))}
      </ol>

      <form onSubmit={onSubmit} className="form create-form">
        {stepProblem && <p role="alert" className="form-error">{stepProblem}</p>}
        {stepErrors.map((m) => (
          <p key={m} role="alert" className="form-error">{m}</p>
        ))}

        {step === 0 && (
          <>
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
            </label>
            <DetailsFields values={details} onChange={setDetails} section="basic" />
            <div className="banner-field">
              <span className="banner-field-label">Banner image (optional)</span>
              <div className="banner-card">
                <input ref={bannerInput} type="file" accept="image/*" onChange={onPickBanner} aria-label="Choose a banner image" hidden />
                {bannerFile && bannerPreview ? (
                  <>
                    <img className="banner-card-preview" src={bannerPreview} alt="Selected banner preview" />
                    <p className="banner-card-name">{bannerFile.name}</p>
                    <div className="banner-card-actions">
                      <button type="button" onClick={() => bannerInput.current?.click()}>Change</button>
                      <button type="button" onClick={onRemoveBanner}>Remove</button>
                    </div>
                  </>
                ) : (
                  <>
                    <svg className="banner-card-icon" width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                      <rect x="3" y="3" width="18" height="18" rx="2" />
                      <circle cx="9" cy="9" r="1.6" />
                      <path d="m21 15-4.5-4.5L6 21" />
                    </svg>
                    <p>Upload a banner image (16:9 works best)</p>
                    <button type="button" className="banner-card-choose" onClick={() => bannerInput.current?.click()}>Choose Image</button>
                    <p className="banner-card-hint">Any image, up to 10 MB. Cropped to 16:9. Without one, the game art is used.</p>
                  </>
                )}
              </div>
              {bannerNote && <p role="alert" className="form-error">{bannerNote}</p>}
            </div>
          </>
        )}

        {step === 1 && (
          <>
            <h2 className="form-section-title">Game and format</h2>
            <DetailsFields
              values={details}
              onChange={setDetails}
              section="game"
              afterGame={
                <>
                  <label>
                    Format
                    <select
                      value={isLobby ? 'Lobby' : format}
                      onChange={(e) => {
                        if (e.target.value === 'Lobby') {
                          setIsLobby(true)
                        } else {
                          setIsLobby(false)
                          setFormat(e.target.value as Format)
                        }
                      }}
                    >
                      <option value="SingleElimination">Single elimination</option>
                      <option value="DoubleElimination">Double elimination</option>
                      <option value="RoundRobin">Round robin</option>
                      <option value="Lobby">Lobby (battle royale, everyone plays together)</option>
                    </select>
                  </label>
                  <p className="muted">{isLobby ? LOBBY_HINT : FORMAT_HINT[format]}</p>
                  {isLobby && (
                    <>
                      <label>
                        Points per kill
                        <input
                          type="number"
                          min={0}
                          max={1000}
                          value={killPoints}
                          onChange={(e) => setKillPoints(e.target.value)}
                        />
                      </label>
                      <label>
                        Points for 1st, 2nd, 3rd... place
                        <input
                          value={placementPoints}
                          placeholder="10, 6, 5, 4, 3, 2, 1, 1"
                          onChange={(e) => setPlacementPoints(e.target.value)}
                        />
                      </label>
                      <p className="muted">
                        Places past the end of the list score 0. A round's points are the place points plus kills times points per kill.
                      </p>
                    </>
                  )}
                </>
              }
            />
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
            <label>
              Maximum participants
              <input
                type="number"
                min={2}
                value={maxParticipants}
                onChange={(e) => setMaxParticipants(e.target.value)}
                required
              />
            </label>
            <p className="muted">
              {isLobby ? 'Each round, every participant gets a place and a kills count. Points decide the standings.' : format === 'SingleElimination'
                ? `A third-place match is always played, so 1st to 4th are decided (needs 4 or more ${unit}).`
                : format === 'DoubleElimination'
                ? 'Double elimination decides the top four by itself.'
                : 'Round robin ranks everyone by points, then goal difference, then goals scored.'}
            </p>
            {matchLine && <p className="muted">{matchLine}</p>}
          </>
        )}

        {step === 2 && (
          <>
            <h2 className="form-section-title">Settings</h2>
            <DetailsFields values={details} onChange={setDetails} section="settings" />
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
            {participantMode === 'IndividualOnly' && (
              <fieldset>
                <legend>Joining</legend>
                <label>
                  <input
                    type="checkbox"
                    checked={requireApproval}
                    onChange={(e) => setRequireApproval(e.target.checked)}
                  />
                  Approve each join request
                </label>
                <p className="muted">
                  {requireApproval
                    ? 'Players ask to join and you approve them, for example once they have paid.'
                    : 'Anyone who is signed in can join straight away.'}
                </p>
              </fieldset>
            )}
          </>
        )}

        {step === 3 && (
          <>
            <h2 className="form-section-title">Review</h2>
            <dl className="create-review">
              <dt>Name</dt><dd>{name.trim() || '-'}</dd>
              <dt>Description</dt><dd>{p.description ?? '-'}</dd>
              <dt>Banner</dt><dd>{bannerFile ? bannerFile.name : 'Game art'}</dd>
              <dt>Game</dt><dd>{p.game ? gameLabel[p.game] : '-'}</dd>
              <dt>Platform</dt><dd>{platformLabel ?? '-'}</dd>
              <dt>Format</dt><dd>{isLobby ? 'Lobby' : formatLabel[format]}</dd>
              {isLobby && (<><dt>Points</dt><dd>{killPoints} per kill; places: {placementPoints}</dd></>)}
              <dt>Competing</dt><dd>{participantMode === 'SquadOnly' ? 'Teams' : 'Individual players'}, up to {maxParticipants}</dd>
              <dt>Starts</dt><dd>{details.start ? details.start.replace('T', ' ') : '-'}</dd>
              <dt>Registration deadline</dt><dd>{details.deadline ? details.deadline.replace('T', ' ') : '-'}</dd>
              <dt>Prize pool</dt><dd>{p.prize != null ? formatKes(p.prize) : '-'}</dd>
              <dt>Entry fee</dt><dd>{p.entryFee == null ? '-' : p.entryFee === 0 ? 'Free' : formatKes(p.entryFee)}</dd>
              <dt>Rules</dt><dd className="create-review-rules">{p.rules ?? '-'}</dd>
                  <dt>Stream link</dt><dd className="create-review-rules">{p.streamUrl ?? '-'}</dd>
              <dt>Visibility</dt><dd>{visibility}</dd>
              {participantMode === 'IndividualOnly' && (
                <><dt>Joining</dt><dd>{requireApproval ? 'You approve each request' : 'Open to anyone signed in'}</dd></>
              )}
            </dl>
          </>
        )}

        {error && <p role="alert" className="form-error">{error}</p>}
        <div className="form-actions form-actions-full">
          {step < LAST ? (
            <button type="submit" className="btn-primary">Next: {STEPS[step + 1]}</button>
          ) : (
            <button type="submit" className="btn-primary" disabled={busy}>
              {busy ? 'Creating' : 'Create tournament'}
            </button>
          )}
          {step > 0 && <button type="button" onClick={() => goTo(step - 1)} disabled={busy}>Back</button>}
          <button type="button" onClick={() => navigate('/me')} disabled={busy}>Cancel</button>
        </div>
      </form>
    </>
  )
}