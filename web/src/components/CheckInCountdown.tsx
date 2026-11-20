import { useEffect, useState } from 'react'

function format(ms: number): string {
  const total = Math.max(0, Math.floor(ms / 1000))
  const h = Math.floor(total / 3600)
  const m = String(Math.floor((total % 3600) / 60)).padStart(2, '0')
  const s = String(total % 60).padStart(2, '0')
  return h > 0 ? `${h}:${m}:${s}` : `${m}:${s}`
}

// closesAt is an ISO UTC time from the server. Ticks once a second.
export default function CheckInCountdown({ closesAt, label = 'Check-in closes in' }: { closesAt: string; label?: string }) {
  const [now, setNow] = useState(() => Date.now())

  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(t)
  }, [])

  const left = Date.parse(closesAt) - now
  if (Number.isNaN(left)) return null
  if (left <= 0) return <span className="ck-countdown ck-over">Check-in time is up</span>
  return (
    <span className="ck-countdown" role="timer">
      {label} <strong className="mono">{format(left)}</strong>
    </span>
  )
}