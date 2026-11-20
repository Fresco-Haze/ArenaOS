import { useEffect, useState } from 'react'
import { countdownText } from '../lib/countdown'

// A live countdown to a moment. Renders nothing when there is no date or it has passed.
export default function Countdown({ to, label, variant = 'inline' }: { to: string | null | undefined; label: string; variant?: 'inline' | 'stat' }) {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 30000)
    return () => clearInterval(id)
  }, [])
  if (!to) return null
  const text = countdownText(to, now)
  if (!text) return null
  if (variant === 'stat') {
    return (
      <div className="tp-stat">
        <dt>{label}</dt>
        <dd className="num">{text}</dd>
      </div>
    )
  }
  return (
    <span className="countdown">
      {label} <span className="num">{text}</span>
    </span>
  )
}