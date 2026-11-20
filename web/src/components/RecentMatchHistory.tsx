import { Link } from 'react-router'
import { formatDateTime } from '../lib/dates'
import type { MatchHistoryItem } from '../model'
import ErrorBanner from './ErrorBanner'
import LoadingBlock from './LoadingBlock'

const BADGE = { Win: 'badge-success', Loss: 'badge-danger', Draw: 'badge-neutral' } as const
const LETTER = { Win: 'W', Loss: 'L', Draw: 'D' } as const

export default function RecentMatchHistory({
  list,
  error,
  onRetry,
  wins,
  losses,
}: {
  list: MatchHistoryItem[] | null
  error: string | null
  onRetry: () => void
  wins: number
  losses: number
}) {
  return (
    <section className="pc-card" aria-labelledby="pc-hist-h">
      <div className="pc-card-head">
        <h2 id="pc-hist-h">Recent match history</h2>
        {list && list.length > 0 && <span className="muted">Last {list.length} &middot; {wins}W {losses}L overall</span>}
      </div>
      {error ? (
        <ErrorBanner message={error} onRetry={onRetry} />
      ) : list === null ? (
        <LoadingBlock label="Loading match history" />
      ) : list.length === 0 ? (
        <p className="muted">Matches you have played appear here once they are completed.</p>
      ) : (
        <div className="pc-table-wrap">
          <table className="pc-table">
            <thead>
              <tr>
                <th scope="col">Result</th>
                <th scope="col">Opponent</th>
                <th scope="col">Event</th>
                <th scope="col" className="pc-num">Date</th>
              </tr>
            </thead>
            <tbody>
              {list.map((m) => (
                <tr key={m.matchId}>
                  <td><span className={'badge ' + BADGE[m.result]} aria-label={m.result}>{LETTER[m.result]}</span></td>
                  <td><strong>{m.opponent}</strong></td>
                  <td><Link to={`/tournaments/${m.tournamentId}`}>{m.tournament}</Link></td>
                  <td className="pc-num muted">{m.at ? formatDateTime(m.at) : '\u2014'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}