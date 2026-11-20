import { useEffect, useState } from 'react'
import type { ZodType } from 'zod'
import { api } from '../api'

// Like useApi, but keeps the last good data while a reload is in flight,
// so a panel does not vanish and reappear after every save.
export function useStickyApi<T>(path: string, schema: ZodType<T>) {
  const [data, setData] = useState<T | null>(null)
  const [failed, setFailed] = useState(false)
  const [tick, setTick] = useState(0)

  useEffect(() => {
    let cancelled = false
    api(path, schema)
      .then((d) => {
        if (!cancelled) {
          setData(d)
          setFailed(false)
        }
      })
      .catch(() => {
        if (!cancelled) setFailed(true)
      })
    return () => {
      cancelled = true
    }
  }, [path, schema, tick])

  return { data, failed, reload: () => setTick((n) => n + 1) }
}