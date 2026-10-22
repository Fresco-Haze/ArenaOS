import type { ReactNode } from 'react'
import { Game, gameLabel } from '../model'
import { prizeError } from '../lib/details'
import type { DetailsValues } from '../lib/details'

// start is "YYYY-MM-DDTHH:mm" in the device's time zone ("" when unset).
function splitStart(v: string): { date: string; time: string } {
  const [date = '', time = ''] = v.split('T')
  return { date, time }
}

export default function DetailsFields({
  values,
  onChange,
  afterGame,
}: {
  values: DetailsValues
  onChange: (next: DetailsValues) => void
  afterGame?: ReactNode
}) {
  const { date, time } = splitStart(values.start)
  const prizeProblem = values.prize.trim() === '' ? null : prizeError(values.prize)

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
      <label>
        Game (optional)
        <select value={values.game} onChange={(e) => onChange({ ...values, game: e.target.value })}>
          <option value="">Not set</option>
          {Game.options.map((g) => (
            <option key={g} value={g}>{gameLabel[g]}</option>
          ))}
        </select>
      </label>
      {afterGame}
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
    </>
  )
}