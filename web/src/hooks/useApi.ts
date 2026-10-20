import { useEffect, useState } from 'react'
import type { ZodType } from 'zod'
import { api, ApiError } from '../api'

type Settled<T> = { key: string; data: T | null; error: string | null }

// Loads one endpoint. Loading is derived (no result yet for the current
// path/attempt), so no state is set synchronously inside the effect.
export function useApi<T>(path: string, schema: ZodType<T>, retryAnonymously = false) {
  const [attempt, setAttempt] = useState(0)
  const [settled, setSettled] = useState<Settled<T> | null>(null)
  const key = `${path}#${attempt}`

  useEffect(() => {
    let cancelled = false
    api(path, schema, { retryAnonymously })
      .then((data) => {
        if (!cancelled) setSettled({ key, data, error: null })
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setSettled({ key, data: null, error: e instanceof ApiError ? e.message : 'Could not reach the server' })
        }
      })
    return () => {
      cancelled = true
    }
  }, [key, path, schema, retryAnonymously])

  const current = settled !== null && settled.key === key ? settled : null
  return {
    data: current?.data ?? null,
    error: current?.error ?? null,
    retry: () => setAttempt((n) => n + 1),
  }
}