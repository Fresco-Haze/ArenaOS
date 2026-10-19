import { useState } from 'react'
import type { FormEvent } from 'react'
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import { registerUser } from '../auth/authActions'
import { safeNext } from '../lib/safeNext'
import { retrySeconds, useCooldown } from '../lib/rateLimit'

type Field = 'username' | 'email' | 'password'

function fieldOf(err: ApiError): Field | null {
  if (err.code === 'USERNAME_TAKEN') return 'username'
  if (err.code === 'EMAIL_TAKEN') return 'email'
  const d = err.details
  if (d && typeof d === 'object' && 'field' in d && typeof d.field === 'string') {
    return d.field as Field
  }
  return null
}

export default function RegisterPage() {
  const { user, login } = useAuth()
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const next = safeNext(params.get('next'))

  const [username, setUsername] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [fieldErrors, setFieldErrors] = useState<Partial<Record<Field, string>>>({})
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const cooldown = useCooldown()

  if (user) return <Navigate to={next} replace />

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setFieldErrors({})
    setBusy(true)

    try {
      await registerUser(username, email, password)
    } catch (err) {
      setBusy(false)
      const wait = retrySeconds(err)
      if (wait !== null) {
        cooldown.start(wait)
      } else if (err instanceof ApiError) {
        const field = fieldOf(err)
        if (field) setFieldErrors({ [field]: err.message })
        else setError(err.message)
      } else {
        setError('Could not reach the server')
      }
      return
    }

    try {
      await login(username, password)
    } catch {
      navigate(`/login?next=${encodeURIComponent(next)}`, {
        state: { notice: 'Account created — sign in below.' },
      })
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="auth-card">
      <h1>Create an account</h1>
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
          {fieldErrors.username && (
            <span role="alert" className="form-error">{fieldErrors.username}</span>
          )}
        </label>
        <label>
          Email
          <input
            type="email"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            autoComplete="email"
            required
          />
          {fieldErrors.email && (
            <span role="alert" className="form-error">{fieldErrors.email}</span>
          )}
        </label>
        <label>
          Password
          <input
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="new-password"
            required
          />
          {fieldErrors.password && (
            <span role="alert" className="form-error">{fieldErrors.password}</span>
          )}
        </label>
        {cooldown.message && <p role="alert" className="form-error">{cooldown.message}</p>}
        {error && <p role="alert" className="form-error">{error}</p>}
        <button type="submit" className="btn-primary" disabled={busy || cooldown.cooling}>
          {busy ? 'Creating account' : 'Create account'}
        </button>
      </form>
      <p>
        Already have an account?{' '}
        <Link to={`/login?next=${encodeURIComponent(next)}`}>Sign in</Link>
      </p>
    </div>
  )
}