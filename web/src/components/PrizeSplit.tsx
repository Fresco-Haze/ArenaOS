import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import { formatKes } from '../lib/money'
import { MAX_PLACES, clearPrizeSplit, ordinal, savePrizeSplit, splitAmounts, validatePercents } from '../lib/prizeSplit'
import ConfirmDialog from './ConfirmDialog'
import ErrorBanner from './ErrorBanner'

type Props = {
  tournamentId: number
  prize: number | null
  isOwner: boolean
  canEdit: boolean
  data: { prize: number | null; places: { place: number; percent: number; amount: number | null }[] } | null
  error: string | null
  onChanged: () => void
}

// How the prize pool is shared between places. Display only: nothing here pays anyone.
export default function PrizeSplit({ tournamentId, prize, isOwner, canEdit, data, error, onChanged }: Props) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState<string[]>([])
  const [busy, setBusy] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [clearing, setClearing] = useState(false)

  if (prize == null) return null
  const mayEdit = isOwner && canEdit
  if (error) return isOwner ? <ErrorBanner message={error} onRetry={onChanged} /> : null
  if (data === null) return null

  const percents = data.places.map((p) => p.percent)

  function startEdit(initial: number[]) {
    setDraft(initial.map(String))
    setFormError(null)
    setEditing(true)
  }

  async function save(nums: number[]) {
    setBusy(true)
    setFormError(null)
    try {
      await savePrizeSplit(tournamentId, nums)
      setEditing(false)
      onChanged()
    } catch (e) {
      setFormError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  if (!editing) {
    if (percents.length === 0) {
      if (!mayEdit) return null
      return (
        <section className="tp-card ps-card" aria-labelledby="ps-title">
          <h2 id="ps-title" className="tp-section-title">Prize distribution</h2>
          <p className="muted">The prize pool is {formatKes(prize)}. Decide how it is shared between places.</p>
          <button type="button" onClick={() => startEdit([50, 30, 20])}>Set up split</button>
        </section>
      )
    }
    const amounts = splitAmounts(prize, percents)
    return (
      <section className="tp-card ps-card" aria-labelledby="ps-title">
        <h2 id="ps-title" className="tp-section-title">Prize distribution</h2>
        <ol className="ps-rows">
          {percents.map((pct, i) => (
            <li key={i} className="ps-row">
              <span className="ps-place">{ordinal(i + 1)}</span>
              <span className="ps-bar" aria-hidden="true"><span className="ps-bar-fill" style={{ width: pct + '%' }} /></span>
              <span className="ps-pct num">{pct}%</span>
              <span className="ps-amt num">{formatKes(amounts[i] ?? 0)}</span>
            </li>
          ))}
        </ol>
        <p className="muted ps-note">Out of a prize pool of {formatKes(prize)}. This shows the plan only; prizes are paid outside SweatLobby.</p>
        {mayEdit && (
          <div className="ps-actions">
            <button type="button" onClick={() => startEdit(percents)}>Edit split</button>
          </div>
        )}
      </section>
    )
  }

  const nums = draft.map((d) => (d.trim() === '' ? NaN : Number(d)))
  const problem = validatePercents(nums)
  const total = nums.reduce((a, n) => a + (Number.isFinite(n) ? n : 0), 0)
  const preview = nums.every((n) => Number.isInteger(n)) ? splitAmounts(prize, nums) : []

  function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (problem === null) void save(nums)
  }

  return (
    <section className="tp-card ps-card" aria-labelledby="ps-title">
      <h2 id="ps-title" className="tp-section-title">Prize distribution</h2>
      <form className="ps-form" onSubmit={submit}>
        <ol className="ps-edit-rows">
          {draft.map((d, i) => (
            <li key={i} className="ps-edit-row">
              <label htmlFor={`ps-${i}`} className="ps-place">{ordinal(i + 1)}</label>
              <input
                id={`ps-${i}`}
                type="number"
                inputMode="numeric"
                min={1}
                max={100}
                value={d}
                onChange={(e) => setDraft(draft.map((x, j) => (j === i ? e.target.value : x)))}
              />
              <span aria-hidden="true">%</span>
              <span className="ps-amt num muted">{preview[i] !== undefined ? formatKes(preview[i]) : '\u2014'}</span>
              {draft.length > 1 && (
                <button type="button" onClick={() => setDraft(draft.filter((_, j) => j !== i))}>Remove</button>
              )}
            </li>
          ))}
        </ol>
        <p className={'ps-total ' + (total === 100 ? 'ps-total-ok' : 'ps-total-bad')} role="status">
          Total <span className="num">{total}%</span> of 100%
        </p>
        {problem && <p className="muted">{problem}</p>}
        {formError && <p role="alert" className="form-error">{formError}</p>}
        <div className="ps-actions">
          <button type="button" disabled={draft.length >= MAX_PLACES} onClick={() => setDraft([...draft, ''])}>Add place</button>
          <button type="submit" className="btn-primary" disabled={busy || problem !== null}>{busy ? 'Saving' : 'Save split'}</button>
          <button type="button" disabled={busy} onClick={() => setEditing(false)}>Cancel</button>
          {percents.length > 0 && (
            <button type="button" className="btn-danger" disabled={busy} onClick={() => setClearing(true)}>Remove split</button>
          )}
        </div>
      </form>
      <ConfirmDialog
        open={clearing}
        title="Remove prize split"
        confirmLabel="Remove"
        danger
        onConfirm={async () => {
          await clearPrizeSplit(tournamentId)
          setEditing(false)
          onChanged()
        }}
        onClose={() => setClearing(false)}
      >
        <p>The prize distribution will no longer be shown on this tournament.</p>
      </ConfirmDialog>
    </section>
  )
}