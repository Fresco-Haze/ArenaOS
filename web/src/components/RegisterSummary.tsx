import { formatCardDate } from '../lib/cardDate'
import { formatKes } from '../lib/money'
import { formatLabel, gameLabel } from '../model'
import type { Tournament } from '../model'

export default function RegisterSummary({ tournament: t }: { tournament: Tournament }) {
  const mode = t.participantMode === 'SquadOnly' ? 'Squad' : '1v1'
  const game = t.game && t.game !== 'Other' ? gameLabel[t.game] : null
  const fee = t.entryFee == null ? null : t.entryFee === 0 ? 'Free' : formatKes(t.entryFee)
  const rules = (t.rules ?? '').split('\n').map((r) => r.trim()).filter((r) => r.length > 0)
  return (
    <div className="reg-summary">
      <p className="reg-name">{t.name}</p>
      <dl className="reg-facts">
        {game && <div><dt>Game</dt><dd>{game}</dd></div>}
        <div><dt>Format</dt><dd>{mode} &bull; {t.kind === 'Lobby' ? 'Lobby' : formatLabel[t.format]}</dd></div>
        {t.startTime && <div><dt>Starts</dt><dd>{formatCardDate(t.startTime)}</dd></div>}
        {fee && <div><dt>Entry fee</dt><dd>{fee}</dd></div>}
      </dl>
      {rules.length > 0 && (
        <details className="reg-rules">
          <summary>Tournament rules ({rules.length})</summary>
          <ul>
            {rules.map((r, i) => (
              <li key={i}>{r}</li>
            ))}
          </ul>
        </details>
      )}
    </div>
  )
}