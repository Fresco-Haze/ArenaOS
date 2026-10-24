import { useState } from 'react'
import type { FormEvent } from 'react'
import { Link } from 'react-router'
import { ApiError } from '../api'
import { requestPasswordReset } from '../auth/authActions'
import { retrySeconds, useCooldown } from '../lib/rateLimit'
import AuthBrand from '../components/AuthBrand'
import AuthField from '../components/AuthField'

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState('')
  const [busy, setBusy] = useState(false)
  const [sent, setSent] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const cooldown = useCooldown()

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)
    try {
      await requestPasswordReset(email.trim())
      setSent(true)
    } catch (err) {
      const wait = retrySeconds(err)
      if (wait !== null) cooldown.start(wait)
      else setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="auth-page">
      <Link to="/login" className="auth-back" aria-label="Back to sign in">&larr; Back</Link>
      <AuthBrand />
      <h1 className="auth-title">Forgot password?</h1>
      {sent ? (
        <>
          <p role="status" className="form-notice">
            If that email has an account, we&rsquo;ve sent a reset link. It works for 30 minutes.
          </p>
          <p className="auth-switch"><Link to="/login">Back to sign in</Link></p>
        </>
      ) : (
        <>
          <p className="muted auth-sub">Enter your email and we&rsquo;ll send you a reset link.</p>
          <form onSubmit={onSubmit} className="auth-form">
            <AuthField
              label="Email"
              icon="mail"
              type="email"
              placeholder="you@example.com"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              autoFocus
              required
            />
            {cooldown.message && <p role="alert" className="form-error">{cooldown.message}</p>}
            {error && <p role="alert" className="form-error">{error}</p>}
            <button type="submit" className="btn-primary auth-submit" disabled={busy || cooldown.cooling}>
              {busy ? 'Sending' : 'Send reset link'}
            </button>
          </form>
        </>
      )}
    </div>
  )
}