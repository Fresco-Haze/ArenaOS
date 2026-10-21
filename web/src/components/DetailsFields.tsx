import { Game, gameLabel } from '../model'
import { PRIZE_MAX } from '../lib/details'
import type { DetailsValues } from '../lib/details'

export default function DetailsFields({
  values,
  onChange,
}: {
  values: DetailsValues
  onChange: (next: DetailsValues) => void
}) {
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
      <label>
        Start date and time (optional)
        <input
          type="datetime-local"
          value={values.start}
          onChange={(e) => onChange({ ...values, start: e.target.value })}
        />
      </label>
      <p className="muted">Uses this device&rsquo;s time zone. Everyone sees it in their own.</p>
      <label>
        Prize (optional)
        <input
          value={values.prize}
          maxLength={PRIZE_MAX}
          placeholder="For example: KSh 50,000 and a trophy"
          onChange={(e) => onChange({ ...values, prize: e.target.value })}
        />
        <span className="muted">{values.prize.length}/{PRIZE_MAX}</span>
      </label>
    </>
  )
}