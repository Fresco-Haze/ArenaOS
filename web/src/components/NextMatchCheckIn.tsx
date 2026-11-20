import { useApi } from '../hooks/useApi'
import { CheckInView } from '../model'
import CheckInCountdown from './CheckInCountdown'

// Shows the check-in countdown for the tournament of the player's next match, when there is one.
export default function NextMatchCheckIn({ tournamentId }: { tournamentId: number }) {
  const ck = useApi(`/tournaments/${tournamentId}/check-in`, CheckInView)
  const d = ck.data
  if (!d || !d.open || !d.closesAt) return null
  return (
    <div className="pc-next-ck">
      <CheckInCountdown closesAt={d.closesAt} />
    </div>
  )
}