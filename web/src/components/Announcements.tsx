import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import { formatCardDate } from '../lib/cardDate'
import { MAX_ANNOUNCEMENT, deleteAnnouncement, postAnnouncement } from '../lib/announcements'
import type { AnnouncementItem } from '../lib/announcements'
import ConfirmDialog from './ConfirmDialog'
import EmptyState from './EmptyState'
import ErrorBanner from './ErrorBanner'
import LoadingBlock from './LoadingBlock'

type Props = {
  tournamentId: number
  isOwner: boolean
  items: AnnouncementItem[] | null
  error: string | null
  onChanged: () => void
}

export default function Announcements({ tournamentId, isOwner, items, error, onChanged }: Props) {
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [formError, setFormError] = useState<string | null>(null)
  const [removing, setRemoving] = useState<AnnouncementItem | null>(null)

  async function submit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    const body = text.trim()
    if (!body) return
    setBusy(true)
    setFormError(null)
    try {
      await postAnnouncement(tournamentId, body)
      setText('')
      onChanged()
    } catch (err) {
      setFormError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="tp-card" aria-labelledby="ann-title">
      <h2 id="ann-title" className="tp-section-title">Announcements</h2>

      {isOwner && (
        <form className="ann-form" onSubmit={(e) => void submit(e)}>
          <label className="sr-only" htmlFor="ann-text">New announcement</label>
          <textarea
            id="ann-text"
            value={text}
            maxLength={MAX_ANNOUNCEMENT}
            onChange={(e) => setText(e.target.value)}
            placeholder="Share an update with everyone following this tournament"
          />
          <div className="ann-form-row">
            <span className="ann-count">{text.length}/{MAX_ANNOUNCEMENT}</span>
            <button type="submit" className="btn-primary" disabled={busy || text.trim() === ''}>
              {busy ? 'Posting' : 'Post announcement'}
            </button>
          </div>
          {formError && <p role="alert" className="form-error">{formError}</p>}
        </form>
      )}

      {error ? (
        <ErrorBanner message={error} onRetry={onChanged} />
      ) : items === null ? (
        <LoadingBlock label="Loading announcements" />
      ) : items.length === 0 ? (
        <EmptyState title="No announcements yet">
          {isOwner ? 'Post the first update above.' : 'The organizer has not posted anything.'}
        </EmptyState>
      ) : (
        <ul className="ann-list">
          {items.map((a) => (
            <li key={a.id} className="ann-item">
              <p className="ann-body">{a.body}</p>
              <div className="ann-meta">
                <span>{formatCardDate(a.createdAt)}</span>
                {isOwner && (
                  <button type="button" className="btn-danger ann-delete" onClick={() => setRemoving(a)}>Delete</button>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}

      <ConfirmDialog
        open={removing !== null}
        title="Delete announcement"
        confirmLabel="Delete"
        danger
        onConfirm={async () => {
          if (removing) {
            await deleteAnnouncement(tournamentId, removing.id)
            onChanged()
          }
        }}
        onClose={() => setRemoving(null)}
      >
        <p>This removes the announcement for everyone.</p>
      </ConfirmDialog>
    </section>
  )
}