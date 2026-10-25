import { useState } from 'react'
import type { ChangeEvent, FormEvent } from 'react'
import { ApiError } from '../api'
import { useAuth } from '../auth/context'
import type { SessionUser } from '../auth/context'
import { changePassword, removeAvatar, saveFullName, uploadAvatar } from '../lib/accountActions'
import { resizeToJpeg } from '../lib/avatarImage'
import PageHeader from '../components/PageHeader'
import Avatar from '../components/Avatar'

function AvatarForm() {
  const { user, setHasAvatar } = useAuth()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function onPick(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    e.target.value = ''
    if (!file) return
    setError(null)
    if (!file.type.startsWith('image/')) {
      setError('Choose an image file')
      return
    }
    if (file.size > 10 * 1024 * 1024) {
      setError('That image is too large (10 MB at most)')
      return
    }
    setBusy(true)
    try {
      const blob = await resizeToJpeg(file)
      await uploadAvatar(blob)
      setHasAvatar(true)
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not use that image')
    } finally {
      setBusy(false)
    }
  }

  async function onRemove() {
    setError(null)
    setBusy(true)
    try {
      await removeAvatar()
      setHasAvatar(false)
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="form avatar-form">
      <h2 className="form-section-title">Picture</h2>
      <div className="avatar-row">
        <Avatar className="profile-avatar" />
        <div>
          <input type="file" accept="image/*" onChange={(e) => void onPick(e)} disabled={busy} aria-label="Choose a picture" />
          {user?.hasAvatar && (
            <button type="button" onClick={() => void onRemove()} disabled={busy}>Remove picture</button>
          )}
        </div>
      </div>
      <p className="muted">Cropped to a square and shrunk before it is uploaded. JPEG, PNG and similar images work.</p>
      {error && <p role="alert" className="form-error">{error}</p>}
    </div>
  )
}

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
      <AvatarForm />
      <NameForm />
      <PasswordForm />
    </>
  )
}