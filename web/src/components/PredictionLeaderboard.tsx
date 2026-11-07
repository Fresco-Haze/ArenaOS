import { useApi } from '../hooks/useApi'
import { LeaderboardList } from '../lib/predictions'
import type { Tournament } from '../model'
import EmptyState from './EmptyState'
import ErrorBanner from './ErrorBanner'
import LoadingBlock from './LoadingBlock'
import '../lobby.css'

// Who called the most match winners right in this tournament. Free points, no money.
export default function PredictionLeaderboard({ tournament }: { tournament: Tournament }) {
  const id = tournament.tournamentId
  const { data, error, retry } = useApi(`/tournaments/${id}/predictions/leaderboard`, LeaderboardList, true)

  if (error) return <ErrorBanner message={error} onRetry={retry} />
  if (!data) return <LoadingBlock label="Loading predictions" rows={4} />

  return (
    <>
      <h2 className="tp-section-title">Predictions</h2>
      <p className="muted">Free points, no money. One point for every match winner you called right.</p>
      {data.length === 0 ? (
        <EmptyState title="No scores yet">
          The table fills in as predicted matches are played.
        </EmptyState>
      ) : (
        <div className="lobby-wrap">
          <table className="lobby-table">
            <thead>
              <tr>
                <th className="num">#</th>
                <th>Name</th>
                <th className="num">Correct</th>
                <th className="num">Wrong</th>
                <th className="num">Points</th>
              </tr>
            </thead>
            <tbody>
              {data.map((r) => (
                <tr key={r.userId}>
                  <td className="num">{r.rank}</td>
                  <td>{r.username}</td>
                  <td className="num">{r.correct}</td>
                  <td className="num">{r.wrong}</td>
                  <td className="num">{r.points}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </>
  )
}