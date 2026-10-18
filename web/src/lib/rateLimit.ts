import { useEffect, useState } from 'react'
import { ApiError } from '../api'

// Seconds to wait if this error is a rate-limit (429) response, otherwise null.
export function retrySeconds(err: unknown): number | null {
  if (!(err instanceof ApiError) || err.code !== 'TOO_MANY_ATTEMPTS') return null
  const d = err.details
  if (d && typeof d === 'object' && 'retryAfterSeconds' in d && typeof d.retryAfterSeconds === 'number') {
    return Math.max(1, Math.ceil(d.retryAfterSeconds))
  }
  return 60
}

export function waitMessage(seconds: number): string {
  const minutes = Math.ceil(seconds / 60)
  return minutes <= 1
    ? 'Too many attempts. Please try again in about a minute.'
    : `Too many attempts. Please try again in about ${minutes} minutes.`
}

// Holds a "try again later" state that clears itself when the wait is over.
export function useCooldown() {
  const [state, setState] = useState<{ until: number; message: string } | null>(null)
  const until = state?.until ?? null

  useEffect(() => {
    if (until === null) return
    const t = setTimeout(() => setState(null), Math.max(0, until - Date.now()))
    return () => clearTimeout(t)
  }, [until])

  return {
    cooling: state !== null,
    message: state?.message ?? null,
    start: (seconds: number) =>
      setState({ until: Date.now() + seconds * 1000, message: waitMessage(seconds) }),
  }
}