import { useApi } from '../hooks/useApi'
import { EMPTY_PROFILE, RECRUITMENT_LABEL, REGIONS } from '../lib/teamProfile'
import type { ProfileDraft, Recruitment } from '../lib/teamProfile'
import { GameList } from '../model'

export default function TeamProfileFields({
  value,
  onChange,
  idPrefix,
}: {
  value: ProfileDraft
  onChange: (next: ProfileDraft) => void
  idPrefix: string
}) {
  const games = useApi('/games', GameList)
  const names = games.data ? games.data.map((g) => g.name) : []
  const set = (patch: Partial<ProfileDraft>) => onChange({ ...EMPTY_PROFILE, ...value, ...patch })

  return (
    <div className="tm-profile-fields">
      <div className="tm-profile-row">
        <label htmlFor={`${idPrefix}-tag`}>
          Tag <span className="muted">3 to 4 letters or numbers</span>
          <input
            id={`${idPrefix}-tag`}
            value={value.tag}
            maxLength={4}
            placeholder="SWL"
            autoComplete="off"
            onChange={(e) => set({ tag: e.target.value.toUpperCase().replace(/[^A-Z0-9]/g, '') })}
          />
        </label>
        <label htmlFor={`${idPrefix}-game`}>
          Primary game
          <select id={`${idPrefix}-game`} value={value.game} onChange={(e) => set({ game: e.target.value })}>
            <option value="">No primary game</option>
            {value.game !== '' && !names.includes(value.game) && <option value={value.game}>{value.game}</option>}
            {names.map((n) => (
              <option key={n} value={n}>{n}</option>
            ))}
          </select>
        </label>
        <label htmlFor={`${idPrefix}-region`}>
          Region
          <select id={`${idPrefix}-region`} value={value.region} onChange={(e) => set({ region: e.target.value })}>
            <option value="">Not set</option>
            {REGIONS.map((r) => (
              <option key={r} value={r}>{r}</option>
            ))}
          </select>
        </label>
      </div>
      <fieldset className="tm-recruit">
        <legend>Recruitment status</legend>
        {(['OpenTryouts', 'InviteOnly'] as Recruitment[]).map((r) => (
          <label key={r} className="tm-radio">
            <input
              type="radio"
              name={`${idPrefix}-recruit`}
              checked={value.recruitment === r}
              onChange={() => set({ recruitment: r })}
            />
            {RECRUITMENT_LABEL[r]}
          </label>
        ))}
      </fieldset>
    </div>
  )
}