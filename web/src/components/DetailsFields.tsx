import type { ReactNode } from 'react'
import { Game, gameLabel } from '../model'
import { DESCRIPTION_MAX, PLATFORMS, RULES_MAX, deadlineError, feeError, prizeError } from '../lib/details'
import type { DetailsValues } from '../lib/details'

// start is "YYYY-MM-DDTHH:mm" in the device's time zone ("" when unset).
function splitStart(v: string): { date: string; time: string } {
  const [date = '', time = ''] = v.split('T')
  return { date, time }
}

// 'all' shows everything (Edit details). The Create wizard shows one part per step.
export type DetailsSection = 'all' | 'basic' | 'game' | 'settings'

export default function DetailsFields({
  values,
  onChange,
  afterGame,
  section = 'all',
}: {
  values: DetailsValues
  onChange: (next: DetailsValues) => void
  afterGame?: ReactNode
  section?: DetailsSection
}) {
  const show = (s: DetailsSection) => section === 'all' || section === s
  const { date, time } = splitStart(values.start)
  const dl = splitStart(values.deadline)
  const deadlineProblem = deadlineError(values)

  function setDeadline(nextDate: string, nextTime: string) {
    if (!nextDate && !nextTime) {
      onChange({ ...values, deadline: '' })
      return
    }
    onChange({ ...values, deadline: `${nextDate}T${nextDate ? nextTime || '18:00' : nextTime}` })
  }
  const prizeProblem = values.prize.trim() === '' ? null : prizeError(values.prize)
  const feeProblem = values.entryFee.trim() === '' ? null : feeError(values.entryFee)

  function setStart(nextDate: string, nextTime: string) {
    if (!nextDate && !nextTime) {
      onChange({ ...values, start: '' })
      return
    }
    // A date with no time starts at 6:00 PM; a time with no date is kept but incomplete.
    onChange({ ...values, start: `${nextDate}T${nextDate ? nextTime || '18:00' : nextTime}` })
  }

  return (
    <>
      {show('game') && (
        <label>
          Game (optional)
          <select value={values.game} onChange={(e) => onChange({ ...values, game: e.target.value })}>
            <option value="">Not set</option>
            {Game.options.map((g) => (
              <option key={g} value={g}>{gameLabel[g]}</option>
            ))}
          </select>
        </label>
      )}
      {show('game') && afterGame}
      {show('settings') && (
        <>
          <div className="form-row-2">
            <label>
              Start date (optional)
              <input type="date" value={date} onChange={(e) => setStart(e.target.value, time)} />
            </label>
            <label>
              Start time
              <input type="time" value={time} onChange={(e) => setStart(date, e.target.value)} />
            </label>
          </div>
          <p className="muted">Uses this device&rsquo;s time zone. Everyone sees it in their own.</p>
          <div className="form-row-2">
            <label>
              Registration deadline (optional)
              <input type="date" value={dl.date} onChange={(e) => setDeadline(e.target.value, dl.time)} />
            </label>
            <label>
              Deadline time
              <input type="time" value={dl.time} onChange={(e) => setDeadline(dl.date, e.target.value)} />
            </label>
          </div>
          {deadlineProblem && <span role="alert" className="form-error">{deadlineProblem}</span>}
          <label>
            Prize pool (optional)
            <span className="kes-input">
              <span className="kes-prefix" aria-hidden="true">KSh</span>
              <input
                inputMode="numeric"
                value={values.prize}
                placeholder="e.g. 50,000"
                onChange={(e) => onChange({ ...values, prize: e.target.value })}
              />
            </span>
            {prizeProblem && <span role="alert" className="form-error">{prizeProblem}</span>}
          </label>
          <label>
            Entry fee (optional)
            <span className="kes-input">
              <span className="kes-prefix" aria-hidden="true">KSh</span>
              <input
                inputMode="numeric"
                value={values.entryFee}
                placeholder="0 for free"
                onChange={(e) => onChange({ ...values, entryFee: e.target.value })}
              />
            </span>
            {feeProblem && <span role="alert" className="form-error">{feeProblem}</span>}
          </label>
          <p className="muted">Shown to players only. SweatLobby does not collect payments, so you collect the fee yourself.</p>
        </>
      )}
      {show('game') && (
        <label>
          Platform (optional)
          <select value={values.platform} onChange={(e) => onChange({ ...values, platform: e.target.value })}>
            <option value="">Not set</option>
            {PLATFORMS.map((p) => (
              <option key={p.value} value={p.value}>{p.label}</option>
            ))}
          </select>
        </label>
      )}
      {show('basic') && (
        <label>
          Description (optional)
          <textarea
            value={values.description}
            maxLength={DESCRIPTION_MAX}
            rows={4}
            placeholder="Tell players about your tournament..."
            onChange={(e) => onChange({ ...values, description: e.target.value })}
          />
          <span className="muted">{values.description.length}/{DESCRIPTION_MAX}</span>
        </label>
      )}
      {show('settings') && (
        <label>
          Tournament rules (optional)
          <textarea
            value={values.rules}
            maxLength={RULES_MAX}
            rows={5}
            placeholder="One rule per line"
            onChange={(e) => onChange({ ...values, rules: e.target.value })}
          />
          <span className="muted">{values.rules.length}/{RULES_MAX}</span>
        </label>
      )}
    </>
  )
}