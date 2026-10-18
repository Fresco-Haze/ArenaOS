import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import { safeNext } from '../lib/safeNext'
import { retrySeconds, useCooldown } from '../lib/rateLimit'
import { Link, Navigate, useLocation, useSearchParams } from 'react-router'

export default function LoginPage() {
  const { user, login } = useAuth()
  const [params] = useSearchParams()
  const location = useLocation()
  const next = safeNext(params.get('next'))
  const notice = (location.state as { notice?: string } | null)?.notice ?? null

  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const cooldown = useCooldown()

  if (user) return <Navigate to={next} replace />

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)
    try {
      await login(username, password)
    } catch (err) {
      const wait = retrySeconds(err)
      if (wait !== null) cooldown.start(wait)
      else setError(err instanceof ApiError ? err.message : 'Could not reach the server')
      setPassword('')
      setBusy(false)
    }
  }

  return (
    <>
      <h1>Sign in</h1>
      {notice && <p role="status" className="form-notice">{notice}</p>}
      <form onSubmit={onSubmit} className="form">
        <label>
          Username
          <input
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            autoComplete="username"
            autoFocus
            required
          />
        </label>
        <label>
          Password
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password"
            required
          />
        </label>
        {cooldown.message && <p role="alert" className="form-error">{cooldown.message}</p>}
        {error && <p role="alert" className="form-error">{error}</p>}
        <button type="submit" className="btn-primary" disabled={busy || cooldown.cooling}>
          {busy ? 'Signing in' : 'Sign in'}
        </button>
      </form>

      <p>
        Don't have an account?{' '}
        <Link to={`/register?next=${encodeURIComponent(next)}`}>
          Register
        </Link>
      </p>
    </>
  )
}