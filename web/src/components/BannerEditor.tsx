import { useState } from 'react'
import type { ChangeEvent } from 'react'
import { ApiError } from '../api'
import { bumpBanner } from '../lib/banner'
import { resizeBannerToJpeg } from '../lib/bannerImage'
import { removeBanner, uploadBanner } from '../lib/tournamentActions'
import ConfirmDialog from './ConfirmDialog'

// An "Edit banner" button for the organizer, sitting on the banner itself.
export default function BannerEditor({ tournamentId }: { tournamentId: number }) {
  const [open, setOpen] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [note, setNote] = useState<string | null>(null)

  async function onPick(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    e.target.value = ''
    if (!file) return
    setError(null)
    setNote(null)
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
      const blob = await resizeBannerToJpeg(file)
      await uploadBanner(tournamentId, blob)
      bumpBanner()
      setNote('Banner saved.')
    } catch (err) {
      setError(err instanceof ApiError ? err.message : err instanceof Error ? err.message : 'Could not use that image')
    } finally {
      setBusy(false)
    }
  }

  async function onRemove() {
    setError(null)
    setNote(null)
    setBusy(true)
    try {
      await removeBanner(tournamentId)
      bumpBanner()
      setNote('Banner removed. The game art shows instead.')
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <button type="button" className="tp-banner-edit" onClick={() => { setNote(null); setError(null); setOpen(true) }}>
        Edit banner
      </button>
      <ConfirmDialog
        open={open}
        title="Banner"
        confirmLabel="Done"
        onConfirm={async () => {}}
        onClose={() => setOpen(false)}
      >
        <input type="file" accept="image/*" onChange={(e) => void onPick(e)} disabled={busy} aria-label="Choose a banner image" />
        <p>
          <button type="button" onClick={() => void onRemove()} disabled={busy}>Remove banner</button>
        </p>
        <p className="muted">Cropped to 16:9 and shrunk before it is uploaded. Without one, the game art is used.</p>
        {error && <p role="alert" className="form-error">{error}</p>}
        {note && <p role="status">{note}</p>}
      </ConfirmDialog>
    </>
  )
}