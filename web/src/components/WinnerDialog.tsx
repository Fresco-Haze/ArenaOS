import { useState } from 'react'
import ConfirmDialog from './ConfirmDialog'
import { recordResult } from '../lib/tournamentActions'
import type { TournamentFormat } from '../model'

type Props = {
  open: boolean
  matchId: number
  nameA: string
  nameB: string
  format: TournamentFormat
  onDone: () => Promise<void>
  onClose: () => void
}

type Choice = 'A' | 'B' | 'Draw' | null

export default function WinnerDialog({ open, matchId, nameA, nameB, format, onDone, onClose }: Props) {
  const [choice, setChoice] = useState<Choice>(null)

  function reset() {
    setChoice(null)
  }

  async function handleSubmit() {
    if (choice === null) return
    if (choice === 'Draw') {
      await recordResult(matchId, { type: 'Draw' })
    } else {
      await recordResult(matchId, { type: 'Winner', winner: choice })
    }
    await onDone()
    reset()
  }

  return (
    <ConfirmDialog
      open={open}
      title="Declare winner"
      confirmLabel="Confirm result"
      confirmDisabled={choice === null}
      onConfirm={handleSubmit}
      onClose={() => {
        reset()
        onClose()
      }}
    >
      <fieldset>
        <legend>Who won?</legend>
        <label>
          <input
            type="radio"
            name={`winner-${matchId}`}
            checked={choice === 'A'}
            onChange={() => setChoice('A')}
          />
          {nameA}
        </label>
        <label>
          <input
            type="radio"
            name={`winner-${matchId}`}
            checked={choice === 'B'}
            onChange={() => setChoice('B')}
          />
          {nameB}
        </label>
        {format === 'RoundRobin' && (
          <label>
            <input
              type="radio"
              name={`winner-${matchId}`}
              checked={choice === 'Draw'}
              onChange={() => setChoice('Draw')}
            />
            Draw
          </label>
        )}
      </fieldset>
      <p className="muted">Results can't be changed once recorded.</p>
    </ConfirmDialog>
  )
}