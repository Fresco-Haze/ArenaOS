import { useEffect, useState } from 'react'
import { fetchProviders } from '../lib/googleSignIn'

// True only when the server says Google sign-in is configured. Any failure means off.
export function useGoogleEnabled(): boolean {
  const [enabled, setEnabled] = useState(false)
  useEffect(() => {
    let cancelled = false
    fetchProviders()
      .then((p) => {
        if (!cancelled) setEnabled(p.google)
      })
      .catch(() => undefined)
    return () => {
      cancelled = true
    }
  }, [])
  return enabled
}