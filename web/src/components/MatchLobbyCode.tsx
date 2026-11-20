import { useState } from 'react'
import type { FormEvent } from 'react'
import { ApiError } from '../api'
import { useStickyApi } from '../hooks/useStickyApi'
import { saveLobbyCode } from '../lib/matchRoomActions'
import { LobbyCodeView } from '../model'

// Only people in the match, the organizer and referees can load this; everyone else gets nothing.
// compact = the strip shown at the bottom of the match header; otherwise a standalone card.
export default function MatchLobbyCode({ matchId, compact = false }: { matchId: number; compact?: boolean }) {
  const lobby = useStickyApi(`/matches/${matchId}/lobby-code`, LobbyCodeView)
  const [draft, setDraft] = useState('')
  const [copied, setCopied] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  if (!lobby.data) return null
  const { code, canEdit } = lobby.data

  function copy() {
    if (!code || !navigator.clipboard) return
    void navigator.clipboard.writeText(code).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    })
  }

  async function save(e: FormEvent) {
    e.preventDefault()
    if (draft.trim() === '') return
    setBusy(true)
    setError(null)
    try {
      await saveLobbyCode(matchId, draft)
      setDraft('')
      lobby.reload()
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  const form = canEdit && (
    <form className={compact ? 'mr-lobby-form' : 'mr-row'} onSubmit={(e) => void save(e)}>
      <label className="sr-only" htmlFor={`mr-code-input-${compact ? 'c' : 'f'}`}>Lobby code</label>
      <input
        id={`mr-code-input-${compact ? 'c' : 'f'}`}
        value={draft}
        maxLength={64}
        onChange={(e) => setDraft(e.target.value)}
        placeholder={code ? 'Replace the code' : 'Enter the lobby code'}
        autoComplete="off"
      />
      <button type="submit" className="btn-primary" disabled={busy || draft.trim() === ''}>
        {code ? 'Replace' : 'Set code'}
      </button>
    </form>
  )

  if (compact) {
    return (
      <div className="mr-lobby-strip">
        <span className="mr-strip-label">Lobby code</span>
        {code ? (
          <>
            <span className="mr-code-value mr-code-small">{code}</span>
            <button type="button" onClick={copy}>{copied ? 'Copied' : 'Copy'}</button>
          </>
        ) : (
          <span className="muted">{canEdit ? 'Not set yet' : 'Not shared yet'}</span>
        )}
        {form}
        {error && <span role="alert" className="form-error">{error}</span>}
      </div>
    )
  }

  return (
    <section className="pc-card mr-card" aria-labelledby="mr-code-h">
      <h2 id="mr-code-h" className="pc-card-head">Lobby code</h2>
      {code ? (
        <div className="mr-code">
          <span className="mr-code-value">{code}</span>
          <button type="button" onClick={copy}>{copied ? 'Copied' : 'Copy'}</button>
        </div>
      ) : (
        <p className="muted">
          {canEdit ? 'No lobby code yet. Set one so the players can join.' : 'The referee has not shared a lobby code yet.'}
        </p>
      )}
      {form}
      {error && <p role="alert" className="form-error">{error}</p>}
    </section>
  )
}