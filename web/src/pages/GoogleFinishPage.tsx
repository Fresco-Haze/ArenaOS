import { useEffect, useState } from 'react'
import type { FormEvent } from 'react'
import { Link, Navigate, useNavigate, useSearchParams } from 'react-router'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import AuthBrand from '../components/AuthBrand'
import AuthField from '../components/AuthField'
import { clearGoogleNext, finishGoogle, finishLoginOnce, peekGoogleNext, retryInfo } from '../lib/googleSignIn'

type View = { kind: 'working' } | { kind: 'form' } | { kind: 'failed'; message: string }

const NO_CODE = 'This sign-in link is not valid. Please try again.'

// Where Google sends people back to. A returning user is signed in at once.
// A new user picks a username and confirms their age first.
export default function GoogleFinishPage() {
  const { user, completeLogin } = useAuth()
  const navigate = useNavigate()
  const [params] = useSearchParams()
  const [initial] = useState(() => ({
    code: params.get('code') || null,
    isNew: params.get('new') === '1',
    next: peekGoogleNext(),
  }))
  const [code, setCode] = useState<string | null>(initial.code)
  const [view, setView] = useState<View>(() =>
    initial.code === null ? { kind: 'failed', message: NO_CODE } : initial.isNew ? { kind: 'form' } : { kind: 'working' },
  )
  const [username, setUsername] = useState('')
  const [age, setAge] = useState(false)
  const [fieldError, setFieldError] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  // Take the one-time code out of the address bar. It was already copied into state.
  useEffect(() => {
    navigate('/login/google', { replace: true })
  }, [navigate])

  useEffect(() => {
    if (!initial.code || initial.isNew) return
    let cancelled = false
    finishLoginOnce(initial.code)
      .then((res) => {
        if (cancelled) return
        clearGoogleNext()
        completeLogin(res, true)
      })
      .catch((err: unknown) => {
        if (cancelled) return
        setView({ kind: 'failed', message: err instanceof ApiError ? err.message : 'Could not reach the server' })
      })
    return () => {
      cancelled = true
    }
  }, [initial, completeLogin])

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (!code) return
    setError(null)
    setFieldError(null)
    setBusy(true)
    try {
      const res = await finishGoogle(code, username.trim(), age)
      clearGoogleNext()
      completeLogin(res, true)
    } catch (err) {
      setBusy(false)
      if (!(err instanceof ApiError)) {
        setError('Could not reach the server')
        return
      }
      if (err.code === 'GOOGLE_CODE_INVALID') {
        setView({ kind: 'failed', message: err.message })
        return
      }
      // The code is used up after an attempt; the server sends a fresh one to retry with.
      const info = retryInfo(err.details)
      if (info.retryCode) setCode(info.retryCode)
      if (err.code === 'USERNAME_TAKEN' || info.field === 'username') setFieldError(err.message)
      else setError(err.message)
    }
  }

  if (user) return <Navigate to={initial.next} replace />

  if (view.kind === 'failed') {
    return (
      <div className="auth-page">
        <AuthBrand />
        <h1 className="auth-title">Google sign-in</h1>
        <p role="alert" className="form-error">{view.message}</p>
        <p className="auth-switch">
          <Link to="/login">Back to sign in</Link>
        </p>
      </div>
    )
  }

  if (view.kind === 'working') {
    return (
      <div className="auth-page">
        <AuthBrand />
        <p role="status" className="muted auth-sub">Signing you in</p>
      </div>
    )
  }

  return (
    <div className="auth-page">
      <AuthBrand />
      <h1 className="auth-title">Almost there</h1>
      <p className="muted auth-sub">Choose a username to finish creating your account</p>
      <form onSubmit={onSubmit} className="auth-form">
        <AuthField
          label="Username"
          icon="user"
          placeholder="Choose a username"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          autoComplete="username"
          autoCapitalize="none"
          spellCheck={false}
          autoFocus
          required
          error={fieldError ?? undefined}
        />
        <label className="remember">
          <input type="checkbox" checked={age} onChange={(e) => setAge(e.target.checked)} required />
          <span>
            I am at least 16 and agree to the{' '}
            <Link to="/terms" target="_blank" rel="noreferrer">Terms</Link> and{' '}
            <Link to="/privacy" target="_blank" rel="noreferrer">Privacy Policy</Link>.
          </span>
        </label>
        {error && <p role="alert" className="form-error">{error}</p>}
        <button type="submit" className="btn-primary auth-submit" disabled={busy}>
          {busy ? 'Creating account' : 'Create Account'}
        </button>
      </form>
      <p className="auth-switch">
        <Link to="/login">Cancel</Link>
      </p>
    </div>
  )
}