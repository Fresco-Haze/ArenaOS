import { useApi } from '../hooks/useApi'
import { LobbyStandingsView } from '../lib/lobby'
import { participantName } from '../lib/participants'
import type { Tournament } from '../model'
import EmptyState from './EmptyState'
import ErrorBanner from './ErrorBanner'
import LoadingBlock from './LoadingBlock'
import '../lobby.css'

// The table of a lobby (battle royale style) tournament, best first.
export default function LobbyStandings({ tournament }: { tournament: Tournament }) {
  const id = tournament.tournamentId
  const { data, error, retry } = useApi(`/tournaments/${id}/lobby/standings`, LobbyStandingsView, true)

  if (error) return <ErrorBanner message={error} onRetry={retry} />
  if (!data) return <LoadingBlock label="Loading standings" rows={4} />

  const finished = tournament.state === 'Completed'
  const played = data.standings.some((s) => s.roundsPlayed > 0)

  return (
    <>
      <h2 className="tp-section-title">Standings</h2>
      {!played ? (
        <EmptyState title="No rounds played yet">
          The standings appear here once the organizer records a round.
        </EmptyState>
      ) : (
        <div className="lobby-wrap">
          <table className="lobby-table">
            <thead>
              <tr>
                <th className="num">#</th>
                <th>Name</th>
                <th className="num">Points</th>
                <th className="num">Kills</th>
                <th className="num">Best place</th>
                <th className="num">Rounds</th>
              </tr>
            </thead>
            <tbody>
              {data.standings.map((s) => {
                const champion = finished && data.championParticipantId === s.participantId
                return (
                  <tr key={s.participantId} className={champion ? 'lobby-champ' : undefined}>
                    <td className="num">{s.rank}</td>
                    <td>
                      {participantName(s.participant)}
                      {champion && <span className="lobby-badge">Champion</span>}
                    </td>
                    <td className="num">{s.points}</td>
                    <td className="num">{s.kills}</td>
                    <td className="num">{s.bestPlacement ?? '-'}</td>
                    <td className="num">{s.roundsPlayed}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </>
  )
}
