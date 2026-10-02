import { useState } from 'react'
import ConfirmDialog from './ConfirmDialog'
import { recordEFootballResult } from '../lib/tournamentActions'
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

function ScoreRow({ name, value, onChange }: { name: string; value: number; onChange: (n: number) => void }) {
  return (
    <div className="score-row">
      <span className="score-name">{name}</span>
      <div className="score-stepper">
        <button type="button" onClick={() => onChange(Math.max(0, value - 1))} aria-label={`Decrease ${name}'s score`}>
          −
        </button>
        <input
          type="number"
          min={0}
          className="score-value"
          value={value}
          onChange={(e) => {
            const n = Math.floor(Number(e.target.value))
            onChange(Number.isFinite(n) && n >= 0 ? n : 0)
          }}
        />
        <button type="button" onClick={() => onChange(value + 1)} aria-label={`Increase ${name}'s score`}>
          +
        </button>
      </div>
    </div>
  )
}

export default function EFootballResultDialog({ open, matchId, nameA, nameB, format, onDone, onClose }: Props) {
  const [scoreA, setScoreA] = useState(0)
  const [scoreB, setScoreB] = useState(0)

  function reset() {
    setScoreA(0)
    setScoreB(0)
  }

  async function handleSubmit() {
    await recordEFootballResult(matchId, scoreA, scoreB)
    await onDone()
    reset()
  }

  return (
    <ConfirmDialog
      open={open}
      title="Record score"
      confirmLabel="Submit score"
      onConfirm={handleSubmit}
      onClose={() => {
        reset()
        onClose()
      }}
    >
      <div className="score-entry">
        <ScoreRow name={nameA} value={scoreA} onChange={setScoreA} />
        <ScoreRow name={nameB} value={scoreB} onChange={setScoreB} />
      </div>
      {format === 'RoundRobin' ? (
        <p className="muted">A draw is a valid result in round robin.</p>
      ) : (
        <p className="muted">
          Elimination matches need a decisive result. If the match went to penalties, enter the shootout score.
        </p>
      )}
    </ConfirmDialog>
  )
}