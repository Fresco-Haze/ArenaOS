import { useState } from 'react'
import { useBannerVersion } from '../lib/banner'

// The tournament's banner picture. Renders nothing when there is none, so the
// game art behind it shows through.
export default function BannerImg({ tournamentId }: { tournamentId: number }) {
  const version = useBannerVersion()
  const key = `${tournamentId}:${version}`
  const [failed, setFailed] = useState<string | null>(null)
  if (failed === key) return null
  return (
    <img
      className="tp-banner-img"
      src={`/api/tournaments/${tournamentId}/banner?v=${version}`}
      alt=""
      onError={() => setFailed(key)}
    />
  )
}