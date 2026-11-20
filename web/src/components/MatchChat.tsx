import { useEffect, useRef, useState } from 'react'
import type { FormEvent } from 'react'
import { api, ApiError } from '../api'
import { formatDateTime } from '../lib/dates'
import { postMatchMessage } from '../lib/matchRoomActions'
import { useAuth } from '../auth/context'
import { ChatMessageList } from '../model'
import type { ChatMessage } from '../model'

// Only people in the match, the organizer and referees can load this; for everyone else it renders nothing.
export default function MatchChat({ matchId }: { matchId: number }) {
  const [messages, setMessages] = useState<ChatMessage[]>([])
  const [denied, setDenied] = useState(false)
  const [loaded, setLoaded] = useState(false)
  const [tab, setTab] = useState<'chat' | 'log'>('chat')
  const { user } = useAuth()
  const [draft, setDraft] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [tick, setTick] = useState(0)
  const lastId = useRef(0)
  const listRef = useRef<HTMLUListElement>(null)

  useEffect(() => {
    let cancelled = false
    async function load() {
      try {
        const res = await api(`/matches/${matchId}/messages?after=${lastId.current}`, ChatMessageList)
        if (cancelled) return
        setLoaded(true)
        if (res.messages.length > 0) {
          lastId.current = res.messages[res.messages.length - 1].id
          setMessages((prev) => [...prev, ...res.messages])
        }
      } catch (e) {
        if (!cancelled && e instanceof ApiError && e.status === 403) setDenied(true)
      }
    }
    void load()
    const timer = setInterval(() => {
      if (document.visibilityState === 'visible') void load()
    }, 5000)
    return () => {
      cancelled = true
      clearInterval(timer)
    }
  }, [matchId, tick])

  useEffect(() => {
    const el = listRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [messages, tab])

  if (denied || !loaded) return null

  const shown = messages.filter((m) => m.kind === tab)

  async function send(e: FormEvent) {
    e.preventDefault()
    const text = draft.trim()
    if (text === '') return
    setBusy(true)
    setError(null)
    try {
      await postMatchMessage(matchId, text)
      setDraft('')
      setTick((n) => n + 1)
    } catch (err) {
      setError(err instanceof ApiError ? err.message : 'Could not send the message')
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="pc-card mr-card" aria-labelledby="mr-chat-h">
      <div className="pc-card-head">
        <h2 id="mr-chat-h">{tab === 'chat' ? 'Match chat' : 'Admin log'}</h2>
        <div className="mr-chat-tabs" role="group" aria-label="Chat view">
          <button type="button" aria-pressed={tab === 'chat'} onClick={() => setTab('chat')}>Chat</button>
          <button type="button" aria-pressed={tab === 'log'} onClick={() => setTab('log')}>Admin log</button>
        </div>
      </div>
      {shown.length === 0 ? (
        <p className="muted">{tab === 'chat' ? 'No messages yet. Say hello.' : 'Nothing has been logged yet.'}</p>
      ) : (
        <ul className="mr-chat" ref={listRef}>
          {shown.map((m) =>
            m.kind === 'log' ? (
              <li key={m.id} className="mr-chat-log">
                <strong>{m.author}</strong> {m.body} <span className="muted">&middot; {formatDateTime(m.at)}</span>
              </li>
            ) : (
              <li key={m.id} className={'mr-chat-msg' + (user && m.author.toLowerCase() === user.username.toLowerCase() ? ' mine' : '')}>
                <p className="mr-chat-meta"><strong>{m.author}</strong> <span className="muted">{formatDateTime(m.at)}</span></p>
                <p>{m.body}</p>
              </li>
            ),
          )}
        </ul>
      )}
      {tab === 'chat' && (
        <form className="mr-row" onSubmit={(e) => void send(e)}>
          <label className="sr-only" htmlFor="mr-chat-input">Message</label>
          <input
            id="mr-chat-input"
            value={draft}
            maxLength={500}
            onChange={(e) => setDraft(e.target.value)}
            placeholder="Message"
            autoComplete="off"
          />
          <button type="submit" className="btn-primary" disabled={busy || draft.trim() === ''}>Send</button>
        </form>
      )}
      {error && <p role="alert" className="form-error">{error}</p>}
    </section>
  )
}