import { useState } from 'react'
import ConfirmDialog from './ConfirmDialog'
import { recordResult, correctResult } from '../lib/tournamentActions'
import type { TournamentFormat } from '../model'

type Props = {
  open: boolean
  matchId: number
  nameA: string
  nameB: string
  format: TournamentFormat
  mode?: 'record' | 'correct'
  onDone: () => Promise<void>
  onClose: () => void
}

type Kind = 'Winner' | 'Forfeit' | 'Disqualification'
type Choice = 'A' | 'B' | 'Draw' | null

export default function WinnerDialog({ open, matchId, nameA, nameB, format, mode = 'record', onDone, onClose }: Props) {
  const correcting = mode === 'correct'
  const send = correcting ? correctResult : recordResult
  const [kind, setKind] = useState<Kind>('Winner')
  const [choice, setChoice] = useState<Choice>(null)

  function reset() {
    setKind('Winner')
    setChoice(null)
  }

  // Changing the result type flips what the team choice means, so clear it.
  function pickKind(k: Kind) {
    setKind(k)
    setChoice(null)
  }

  // For a forfeit or a disqualification the organizer names the team that failed;
  // the other team is the one that advances.
  const advancing: 'A' | 'B' | null =
    choice === 'A' || choice === 'B'
      ? kind === 'Winner'
        ? choice
        : choice === 'A'
          ? 'B'
          : 'A'
      : null
  const advancingName = advancing === 'A' ? nameA : advancing === 'B' ? nameB : null

  async function handleSubmit() {
    if (choice === 'Draw') {
      await send(matchId, { type: 'Draw' })
    } else if (advancing !== null) {
      await send(matchId, { type: kind, winner: advancing })
    } else {
      return
    }
    await onDone()
    reset()
  }

  const question =
    kind === 'Winner' ? 'Who won?' : kind === 'Forfeit' ? 'Who forfeited?' : 'Who was disqualified?'

  return (
    <ConfirmDialog
      open={open}
      title={correcting ? 'Correct result' : 'Declare result'}
      confirmLabel={correcting ? 'Save correction' : 'Confirm result'}
      confirmDisabled={choice === null}
      onConfirm={handleSubmit}
      onClose={() => {
        reset()
        onClose()
      }}
    >
      <fieldset>
        <legend>How did it end?</legend>
        <label>
          <input
            type="radio"
            name={`kind-${matchId}`}
            checked={kind === 'Winner'}
            onChange={() => pickKind('Winner')}
          />
          Played to a result
        </label>
        <label>
          <input
            type="radio"
            name={`kind-${matchId}`}
            checked={kind === 'Forfeit'}
            onChange={() => pickKind('Forfeit')}
          />
          Forfeit (a team did not play or withdrew)
        </label>
        <label>
          <input
            type="radio"
            name={`kind-${matchId}`}
            checked={kind === 'Disqualification'}
            onChange={() => pickKind('Disqualification')}
          />
          Disqualification
        </label>
      </fieldset>
      <fieldset>
        <legend>{question}</legend>
        <label>
          <input
            type="radio"
            name={`who-${matchId}`}
            checked={choice === 'A'}
            onChange={() => setChoice('A')}
          />
          {nameA}
        </label>
        <label>
          <input
            type="radio"
            name={`who-${matchId}`}
            checked={choice === 'B'}
            onChange={() => setChoice('B')}
          />
          {nameB}
        </label>
        {format === 'RoundRobin' && kind === 'Winner' && (
          <label>
            <input
              type="radio"
              name={`who-${matchId}`}
              checked={choice === 'Draw'}
              onChange={() => setChoice('Draw')}
            />
            Draw
          </label>
        )}
      </fieldset>
      {advancingName && (
        <p>{kind === 'Winner' ? `${advancingName} wins.` : `${advancingName} advances.`}</p>
      )}
      {correcting ? (
        <p className="muted">
          This replaces the recorded result and updates the rounds that depend on it. It is refused once a
          dependent match has started, or once the tournament is completed.
        </p>
      ) : (
        <p className="muted">
          A result can be corrected later, until a match that depends on it has started.
        </p>
      )}
    </ConfirmDialog>
  )
}