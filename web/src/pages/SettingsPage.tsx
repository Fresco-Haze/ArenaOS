import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import type { SessionUser } from '../auth/context'
import { changePassword, saveFullName } from '../lib/accountActions'
import PageHeader from '../components/PageHeader'

function NameForm() {
  const { user, updateFullName } = useAuth()
  const [name, setName] = useState(user?.fullName ?? '')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setSaved(false)
    setBusy(true)
    const trimmed = name.trim()
    try {
      await saveFullName(trimmed === '' ? null : trimmed)
      updateFullName((trimmed === '' ? null : trimmed) as SessionUser['fullName'])
      setName(trimmed)
      setSaved(true)
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={onSubmit} className="form">
      <h2 className="form-section-title">Profile</h2>
      <label>
        Full name
        <input value={name} onChange={(e) => setName(e.target.value)} maxLength={60} autoComplete="name" />
      </label>
      <p className="muted">Shown on your profile. Leave it empty to show your username instead.</p>
      {error && <p role="alert" className="form-error">{error}</p>}
      {saved && <p role="status">Saved.</p>}
      <button type="submit" className="btn-primary" disabled={busy}>{busy ? 'Saving' : 'Save name'}</button>
    </form>
  )
}

function PasswordForm() {
  const [current, setCurrent] = useState('')
  const [next, setNext] = useState('')
  const [confirm, setConfirm] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [done, setDone] = useState(false)

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setDone(false)
    if (next.length < 8) {
      setError('New password must be at least 8 characters')
      return
    }
    if (next !== confirm) {
      setError('The new passwords do not match')
      return
    }
    setBusy(true)
    try {
      await changePassword(current, next)
      setCurrent('')
      setNext('')
      setConfirm('')
      setDone(true)
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form onSubmit={onSubmit} className="form">
      <h2 className="form-section-title">Password</h2>
      <label>
        Current password
        <input type="password" value={current} onChange={(e) => setCurrent(e.target.value)} autoComplete="current-password" required />
      </label>
      <label>
        New password
        <input type="password" value={next} onChange={(e) => setNext(e.target.value)} autoComplete="new-password" required />
      </label>
      <label>
        Confirm new password
        <input type="password" value={confirm} onChange={(e) => setConfirm(e.target.value)} autoComplete="new-password" required />
      </label>
      {error && <p role="alert" className="form-error">{error}</p>}
      {done && <p role="status">Password changed. Your other devices were signed out.</p>}
      <button type="submit" className="btn-primary" disabled={busy}>{busy ? 'Saving' : 'Change password'}</button>
    </form>
  )
}

export default function SettingsPage() {
  return (
    <>
      <PageHeader title="Settings" />
      <NameForm />
      <PasswordForm />
    </>
  )
}