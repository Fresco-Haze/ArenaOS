import { useEffect, useState } from 'react'
import type { ChangeEvent } from 'react'
import { ApiError } from '../api'
import { useStickyApi } from '../hooks/useStickyApi'
import { formatDateTime } from '../lib/dates'
import { fetchEvidenceBlob, removeEvidence, resizeEvidence, uploadEvidence } from '../lib/matchRoomActions'
import { EvidenceList } from '../model'

function Thumb({ matchId, id }: { matchId: number; id: number }) {
  const [url, setUrl] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    let made: string | null = null
    fetchEvidenceBlob(matchId, id)
      .then((blob) => {
        if (cancelled) return
        made = URL.createObjectURL(blob)
        setUrl(made)
      })
      .catch(() => {
        /* the tile stays empty */
      })
    return () => {
      cancelled = true
      if (made) URL.revokeObjectURL(made)
    }
  }, [matchId, id])

  if (!url) return <div className="mr-ev-thumb" aria-hidden="true" />
  return (
    <a href={url} target="_blank" rel="noopener noreferrer">
      <img className="mr-ev-thumb" src={url} alt="Match evidence screenshot" />
    </a>
  )
}

// Visible and usable only for people in the match, the organizer and referees.
export default function MatchEvidence({ matchId }: { matchId: number }) {
  const list = useStickyApi(`/matches/${matchId}/evidence`, EvidenceList)
  const [note, setNote] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!list.data) return null
  const items = list.data.evidence

  async function onPick(e: ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    e.target.value = ''
    if (!file) return
    setBusy(true)
    setError(null)
    try {
      await uploadEvidence(matchId, await resizeEvidence(file), note)
      setNote('')
      list.reload()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not upload the screenshot')
    } finally {
      setBusy(false)
    }
  }

  async function onRemove(id: number) {
    setError(null)
    try {
      await removeEvidence(matchId, id)
      list.reload()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not remove the screenshot')
    }
  }

  return (
    <section className="pc-card mr-card" aria-labelledby="mr-ev-h">
      <h2 id="mr-ev-h" className="pc-card-head">Evidence</h2>
      <p className="muted">Upload scoreboard screenshots for this match. Only the players, the organizer and referees can see them.</p>
      <div className="mr-row">
        <label className="sr-only" htmlFor="mr-ev-note">Note for the screenshot</label>
        <input
          id="mr-ev-note"
          value={note}
          maxLength={200}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Optional note, e.g. final scoreboard"
          autoComplete="off"
        />
        <label className="tm-file">
          {busy ? 'Uploading' : 'Upload screenshot'}
          <input type="file" accept="image/*" className="sr-only" disabled={busy} onChange={(e) => void onPick(e)} />
        </label>
      </div>
      {error && <p role="alert" className="form-error">{error}</p>}
      {items.length === 0 ? (
        <p className="muted">No screenshots yet.</p>
      ) : (
        <ul className="mr-evidence">
          {items.map((i) => (
            <li key={i.id} className="mr-ev-item">
              <Thumb matchId={matchId} id={i.id} />
              <div className="mr-ev-meta">
                <p><strong>{i.uploadedBy}</strong></p>
                {i.note && <p>{i.note}</p>}
                <p className="muted">{formatDateTime(i.at)}</p>
                {i.canDelete && (
                  <button type="button" onClick={() => void onRemove(i.id)}>Remove</button>
                )}
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}