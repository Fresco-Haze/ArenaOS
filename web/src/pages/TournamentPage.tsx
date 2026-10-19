import { useState } from 'react'
import { Link } from 'react-router'

import { stateBadge } from '../badges'
import { useAuth } from '../auth/context'
import { useTournament } from '../hooks/useTournament'

import { participantName } from '../lib/participants'
import { currentRoundName, matchStats } from '../lib/tournamentStats'
import { formatLabel, stateLabel } from '../model'

import Bracket from '../components/Bracket'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import OrganizerPanel from '../components/OrganizerPanel'
import PageHeader from '../components/PageHeader'
import PlayerLookup from '../components/PlayerLookup'
import StatStrip from '../components/StatStrip'
import type { Stat } from '../components/StatStrip'
import Tabs from '../components/Tabs'

type TabId = 'bracket' | 'players'

export default function TournamentPage({ id }: { id: string }) {
  const { user } = useAuth()
  const { state, reload } = useTournament(id)
  const [tab, setTab] = useState<TabId>('bracket')

  if (state.kind === 'loading') {
    return <LoadingBlock label="Loading tournament" rows={4} />
  }

  if (state.kind === 'notfound') {
    return (
      <EmptyState
        title="Tournament not found"
        action={
          <>
            {!user && (
              <p>
                <Link to={`/login?next=/tournaments/${id}`}>Sign in</Link> to check.
              </p>
            )}
            <p>
              <Link to="/">Back to public tournaments</Link>
            </p>
          </>
        }
      >
        It may not exist, or it may be private.
      </EmptyState>
    )
  }

  if (state.kind === 'error') {
    return (
      <>
        <h1>Tournament</h1>
        <ErrorBanner message={state.message} onRetry={() => void reload()} />
      </>
    )
  }

  const { view, bracket, lastUpdated } = state.data
  const t = view.tournament
  const squads = t.participantMode === 'SquadOnly'
  const unit = squads ? 'teams' : 'players'

  const stats: Stat[] = [
    {
      label: squads ? 'Teams registered' : 'Players registered',
      value: String(view.participants.length),
      sub: `/ ${t.maxParticipants}`,
    },
  ]
  if (bracket) {
    const m = matchStats(bracket)
    stats.push({
      label: 'Matches played',
      value: String(m.played),
      sub: m.total === null ? undefined : `/ ${m.total}`,
    })
    const round = currentRoundName(bracket)
    if (round) stats.push({ label: 'Current round', value: round, text: true })
  }

  return (
    <>
      <div className="stage">
        <PageHeader
          title={t.name}
          status={<span className={'badge ' + stateBadge[t.state]}>{stateLabel[t.state]}</span>}
          meta={
            <>
              {formatLabel[t.format]} &middot; up to {t.maxParticipants} {unit}
              {t.thirdPlaceMatch && <> &middot; third-place match</>} &middot; Organized by{' '}
              {t.organizer}
            </>
          }
        />

        <StatStrip stats={stats} />

        <Tabs<TabId>
          label="Tournament sections"
          active={tab}
          onChange={setTab}
          tabs={[
            { id: 'bracket', label: 'Bracket' },
            { id: 'players', label: squads ? 'Teams' : 'Players', count: view.participants.length },
          ]}
        />

        {tab === 'bracket' ? (
          <div role="tabpanel" id="panel-bracket" aria-labelledby="tab-bracket">
            {t.state === 'Cancelled' && (
              <p role="status" className="muted">
                This tournament was cancelled. Matches that had not finished were not completed.
              </p>
            )}

            {bracket && t.state !== 'Cancelled' && (
              <PlayerLookup bracket={bracket} participants={view.participants} squads={squads} />
            )}

            {bracket ? (
              <Bracket bracket={bracket} tournamentState={t.state} />
            ) : (
              <EmptyState title="No bracket yet">
                The bracket appears here once the organizer generates it.
              </EmptyState>
            )}
          </div>
        ) : (
          <div role="tabpanel" id="panel-players" aria-labelledby="tab-players">
            <h2>
              {squads ? 'Teams' : 'Players'} ({view.participants.length} of {t.maxParticipants})
            </h2>
            {view.participants.length === 0 ? (
              <EmptyState title={squads ? 'No teams registered yet' : 'No players registered yet'}>
                Registered {unit} will appear here.
              </EmptyState>
            ) : (
              <ul className="participants">
                {view.participants.map((p, i) => (
                  <li key={i}>
                    <span className="participant-name">{participantName(p)}</span>
                    {p.type === 'Squad' && (
                      <span className="participant-members">{p.team.members.join(', ')}</span>
                    )}
                  </li>
                ))}
              </ul>
            )}
          </div>
        )}
      </div>

      {view.viewerIsOwner && (
        <OrganizerPanel
          tournament={t}
          bracket={bracket}
          participantCount={view.participants.length}
          registered={view.participants.map(participantName)}
          reload={reload}
        />
      )}

      <p className="toolbar muted">
        <span>Updated at {new Date(lastUpdated).toLocaleTimeString()}</span>

        <button onClick={() => void reload()} disabled={state.refreshing}>
          {state.refreshing ? 'Refreshing' : 'Refresh'}
        </button>
      </p>

      {state.refreshFailed && (
        <p role="status" className="muted">
          Couldn't refresh, retrying.
        </p>
      )}
    </>
  )
}