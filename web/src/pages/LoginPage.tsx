import { useState } from 'react'
import type { FormEvent } from 'react'
import { Link, Navigate, useLocation, useSearchParams } from 'react-router'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import { safeNext } from '../lib/safeNext'
import { retrySeconds, useCooldown } from '../lib/rateLimit'
import AuthBrand from '../components/AuthBrand'
import AuthField from '../components/AuthField'

export default function LoginPage() {
  const { user, login } = useAuth()
  const [params] = useSearchParams()
  const location = useLocation()
  const next = safeNext(params.get('next'))
  const notice = (location.state as { notice?: string } | null)?.notice ?? null

  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [remember, setRemember] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const cooldown = useCooldown()

  if (user) return <Navigate to={next} replace />

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)
    try {
      await login(username, password, remember)
    } catch (err) {
      const wait = retrySeconds(err)
      if (wait !== null) cooldown.start(wait)
      else setError(err instanceof ApiError ? err.message : 'Could not reach the server')
      setPassword('')
      setBusy(false)
    }
  }

  return (
    <div className="auth-page">
      <AuthBrand />
      <h1 className="auth-title">Welcome Back</h1>
      <p className="muted auth-sub">Sign in to continue to your account</p>
      {notice && <p role="status" className="form-notice">{notice}</p>}
      <form onSubmit={onSubmit} className="auth-form">
        <AuthField
          label="Email or username"
          hideLabel
          icon="user"
          placeholder="Email or username"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          autoComplete="username"
          autoCapitalize="none"
          spellCheck={false}
          autoFocus
          required
        />
        <AuthField
          label="Password"
          hideLabel
          icon="lock"
          password
          placeholder="Password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          autoComplete="current-password"
          required
        />
        <label className="remember">
          <input type="checkbox" checked={remember} onChange={(e) => setRemember(e.target.checked)} />
          Remember me
        </label>
        <p className="auth-forgot"><Link to="/forgot-password">Forgot password?</Link></p>
        {cooldown.message && <p role="alert" className="form-error">{cooldown.message}</p>}
        {error && <p role="alert" className="form-error">{error}</p>}
        <button type="submit" className="btn-primary auth-submit" disabled={busy || cooldown.cooling}>
          {busy ? 'Signing in' : 'Sign In'}
        </button>
      </form>
      <p className="auth-switch">
        Don't have an account?{' '}
        <Link to={`/register?next=${encodeURIComponent(next)}`}>Register</Link>
      </p>
    </div>
  )
}