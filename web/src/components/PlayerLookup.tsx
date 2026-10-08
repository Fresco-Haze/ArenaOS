import { useState } from 'react'
import { findParticipants, playerStatus } from '../lib/playerStatus'
import { participantName } from '../lib/participants'
import type { BracketView, Participant } from '../model'

export default function PlayerLookup({
  bracket,
  participants,
  squads,
}: {
  bracket: BracketView
  participants: Participant[]
  squads: boolean
}) {
  const [query, setQuery] = useState('')
  const matches = findParticipants(participants, query)
  const status = matches.length === 1 ? playerStatus(bracket, matches[0]) : null

  return (
    <section className="section" aria-label="Find your match">
      <h2>Find your match</h2>
      <label className="stack-label">
        {squads ? 'Your name or team name' : 'Your name'}
        <input
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Type your name"
          autoComplete="off"
        />
      </label>
      {query.trim() !== '' && matches.length === 0 && (
        <p className="muted">Nobody registered with that name.</p>
      )}
      {matches.length > 1 && (
        <div role="status">
          <p className="muted">Which one are you?</p>
          <div className="match-actions-buttons">
            {matches.slice(0, 8).map((p) => (
              <button key={participantName(p)} type="button" onClick={() => setQuery(participantName(p))}>
                {participantName(p)}
              </button>
            ))}
          </div>
          {matches.length > 8 && <p className="muted">Keep typing to narrow it down.</p>}
        </div>
      )}
      {status && (
        <div role="status">
          <p>
            <strong>{status.name}</strong>: {status.headline}
          </p>
          {status.details.map((d, i) => (
            <p key={i} className="muted">{d}</p>
          ))}
        </div>
      )}
    </section>
  )
}