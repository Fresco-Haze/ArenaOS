import { useState } from 'react'
import type { FormEvent } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router'
import { ApiError } from '../api'
import { resetPassword } from '../auth/authActions'
import { retrySeconds, useCooldown } from '../lib/rateLimit'
import AuthBrand from '../components/AuthBrand'
import AuthField from '../components/AuthField'

export default function ResetPasswordPage() {
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const token = params.get('token') ?? ''
  const [password, setPassword] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const cooldown = useCooldown()

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)
    try {
      await resetPassword(token, password)
      navigate('/login', { state: { notice: 'Password changed. Sign in with your new password.' } })
    } catch (err) {
      const wait = retrySeconds(err)
      if (wait !== null) cooldown.start(wait)
      else setError(err instanceof ApiError ? err.message : 'Could not reach the server')
      setBusy(false)
    }
  }

  return (
    <div className="auth-page">
      <AuthBrand />
      <h1 className="auth-title">Choose a new password</h1>
      {token === '' ? (
        <p className="auth-switch">
          This link is incomplete. <Link to="/forgot-password">Request a new one</Link>.
        </p>
      ) : (
        <form onSubmit={onSubmit} className="auth-form">
          <AuthField
            label="New password"
            icon="lock"
            password
            placeholder="At least 8 characters"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="new-password"
            autoFocus
            required
          />
          {cooldown.message && <p role="alert" className="form-error">{cooldown.message}</p>}
          {error && (
            <p role="alert" className="form-error">
              {error} <Link to="/forgot-password">Request a new link</Link>
            </p>
          )}
          <button type="submit" className="btn-primary auth-submit" disabled={busy || cooldown.cooling}>
            {busy ? 'Saving' : 'Change password'}
          </button>
        </form>
      )}
    </div>
  )
}