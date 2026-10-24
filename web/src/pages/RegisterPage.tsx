import { useState } from 'react'
import type { FormEvent } from 'react'
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import { registerUser } from '../auth/authActions'
import { safeNext } from '../lib/safeNext'
import { retrySeconds, useCooldown } from '../lib/rateLimit'
import AuthBrand from '../components/AuthBrand'
import AuthField from '../components/AuthField'

type Field = 'fullName' | 'username' | 'email' | 'password'

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

  const [fullName, setFullName] = useState('')
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
      await registerUser(username, email, password, fullName.trim())
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
        state: { notice: 'Account created. Sign in below.' },
      })
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="auth-page">
      <Link to={`/login?next=${encodeURIComponent(next)}`} className="auth-back" aria-label="Back to sign in">
        &larr; Back
      </Link>
      <AuthBrand />
      <h1 className="auth-title">Create Your Account</h1>
      <p className="muted auth-sub">Join the ArenaOS community</p>
      <form onSubmit={onSubmit} className="auth-form">
        <AuthField
          label="Full Name"
          icon="user"
          placeholder="John Doe"
          value={fullName}
          onChange={(e) => setFullName(e.target.value)}
          autoComplete="name"
          maxLength={60}
          autoFocus
          required
          error={fieldErrors.fullName}
        />

        <AuthField
          label="Email"
          icon="mail"
          type="email"
          placeholder="you@example.com"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          autoComplete="email"
          required
          error={fieldErrors.email}
        />
        <AuthField
          label="Username"
          icon="user"
          placeholder="Choose a username"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          autoComplete="username"
          required
          error={fieldErrors.username}
        />
        <AuthField
          label="Password"
          icon="lock"
          password
          placeholder="Create a password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          autoComplete="new-password"
          required
          error={fieldErrors.password}
        />
        {cooldown.message && <p role="alert" className="form-error">{cooldown.message}</p>}
        {error && <p role="alert" className="form-error">{error}</p>}
        <button type="submit" className="btn-primary auth-submit" disabled={busy || cooldown.cooling}>
          {busy ? 'Creating account' : 'Create Account'}
        </button>
      </form>
      <p className="auth-switch">
        Already have an account?{' '}
        <Link to={`/login?next=${encodeURIComponent(next)}`}>Sign In</Link>
      </p>
    </div>
  )
}