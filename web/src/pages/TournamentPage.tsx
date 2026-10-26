import { useState } from 'react'
import { Link } from 'react-router'

import { statusClass } from '../badges'
import { useAuth } from '../auth/context'
import { useTournament } from '../hooks/useTournament'

import { participantName } from '../lib/participants'
import { formatCardDate } from '../lib/cardDate'
import { formatKes } from '../lib/money'
import { PLATFORMS } from '../lib/details'
import { formatLabel, gameLabel, stateLabel, type Participant } from '../model'

import Bracket from '../components/Bracket'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import OrganizerPanel from '../components/OrganizerPanel'
import PlayerLookup from '../components/PlayerLookup'
import Tabs from '../components/Tabs'
import JoinBar from '../components/JoinBar'
import BannerImg from '../components/BannerImg'
import BannerEditor from '../components/BannerEditor'
import ConfirmDialog from '../components/ConfirmDialog'
import { removeParticipant } from '../lib/tournamentActions'

type TabId = 'overview' | 'bracket' | 'players'

function PeopleIcon() {
  return (
    <svg className="meta-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <circle cx="6" cy="5.5" r="2.25" />
      <path d="M2 13c0-2.2 1.8-4 4-4s4 1.8 4 4" />
      <circle cx="11.5" cy="6" r="1.75" />
      <path d="M11 9.2c1.8.1 3 1.5 3 3.3" />
    </svg>
  )
}

function CalendarIcon() {
  return (
    <svg className="meta-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <rect x="2.5" y="3.5" width="11" height="10" rx="1.5" />
      <path d="M2.5 6.5h11M5.5 2v3M10.5 2v3" />
    </svg>
  )
}

function TrophyIcon() {
  return (
    <svg className="meta-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path d="M5 2.5h6v3a3 3 0 0 1-6 0v-3zM5 4H2.5v1a2 2 0 0 0 2 2M11 4h2.5v1a2 2 0 0 1-2 2M8 8.5v3M5.5 13.5h5" />
    </svg>
  )
}

export default function TournamentPage({ id }: { id: string }) {
  const { user } = useAuth()
  const { state, reload } = useTournament(id)
  const [tab, setTab] = useState<TabId>('overview')
  const [removing, setRemoving] = useState<Participant | null>(null)

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
  const mode = squads ? 'Squad' : '1v1'
  const gameName = t.game && t.game !== 'Other' ? gameLabel[t.game] : null
  const when = t.startTime ? formatCardDate(t.startTime) : ''
  const canRemove = view.viewerIsOwner && t.state === 'RegistrationOpen'
  const platformName = PLATFORMS.find((p) => p.value === t.platform)?.label ?? null
  const feeText = t.entryFee == null ? null : t.entryFee === 0 ? 'Free' : formatKes(t.entryFee)
  const rulesList = (t.rules ?? '').split('\n').map((r) => r.trim()).filter((r) => r.length > 0)

  return (
    <div className="tp">
      <nav aria-label="Breadcrumb" className="tp-crumbs muted">
        <Link to="/tournaments">Tournaments</Link>
        <span aria-hidden="true">&rsaquo;</span>
        <span>{t.name}</span>
      </nav>

      <section className="tp-head" aria-labelledby="tp-title">
        <div className="tp-art" data-game={t.game ?? 'none'}>
          <BannerImg tournamentId={t.tournamentId} />
          {view.viewerIsOwner && t.state !== 'Completed' && t.state !== 'Cancelled' && (
            <BannerEditor tournamentId={t.tournamentId} />
          )}
          <span className={'badge tp-status ' + statusClass[t.state]}>{stateLabel[t.state]}</span>
        </div>
        <div className="tp-info">
          <h1 id="tp-title" className="tp-title">{t.name}</h1>
          <ul className="tp-meta">
            {gameName && <li>{gameName}</li>}
            <li>
              <PeopleIcon />
              {mode} &bull; {formatLabel[t.format]}
              {t.thirdPlaceMatch && <> &bull; third-place match</>}
            </li>
            <li>Up to {t.maxParticipants} {unit}</li>
            <li>Organized by {t.organizer}</li>
          </ul>
          {(when || t.prize != null) && (
            <ul className="tp-facts">
              {when && <li><CalendarIcon />{when}</li>}
              {t.prize != null && <li className="tp-prize"><TrophyIcon />{formatKes(t.prize)}</li>}
            </ul>
          )}
          {t.registrationDeadline && <p className="muted">Registration closes {formatCardDate(t.registrationDeadline)}</p>}

          <JoinBar tournament={t} signedIn={!!user} registered={view.viewerIsRegistered} requestStatus={view.viewerRequestStatus} onDone={reload} />
          <p className="muted tp-count">{view.participants.length}/{t.maxParticipants} registered</p>
        </div>
      </section>

      <Tabs<TabId>
        label="Tournament sections"
        active={tab}
        onChange={setTab}
        tabs={[
          { id: 'overview', label: 'Overview' },
          { id: 'bracket', label: 'Bracket' },
          { id: 'players', label: squads ? 'Teams' : 'Players', count: view.participants.length },
        ]}
      />

      {tab === 'overview' ? (
        <div role="tabpanel" id="panel-overview" aria-labelledby="tab-overview">
          <section className="tp-card">
            <h2 className="tp-section-title">About this tournament</h2>
            {t.description ? (
              <p className="tp-about-text">{t.description}</p>
            ) : (
              <p className="muted">The organizer has not added a description.</p>
            )}
            <ul className="tp-tiles">
              <li className="tp-tile"><span className="muted">Format</span><strong>{formatLabel[t.format]}</strong></li>
              {gameName && <li className="tp-tile"><span className="muted">Game</span><strong>{gameName}</strong></li>}
              <li className="tp-tile"><span className="muted">Mode</span><strong>{squads ? 'Squads' : 'Individual players'}</strong></li>
              {platformName && <li className="tp-tile"><span className="muted">Platform</span><strong>{platformName}</strong></li>}
              {feeText && <li className="tp-tile"><span className="muted">Entry fee</span><strong>{feeText}</strong></li>}
            </ul>
            {rulesList.length > 0 && (
              <>
                <h3 className="tp-rules-title">Tournament rules</h3>
                <ul className="tp-rules">
                  {rulesList.map((r, i) => (
                    <li key={i}>{r}</li>
                  ))}
                </ul>
              </>
            )}
          </section>
        </div>
      ) : tab === 'bracket' ? (
        <div role="tabpanel" id="panel-bracket" aria-labelledby="tab-bracket">
          <h2 className="tp-section-title">Bracket</h2>
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
          <h2 className="tp-section-title">
            Registered {squads ? 'Teams' : 'Players'} ({view.participants.length}/{t.maxParticipants})
          </h2>
          {view.participants.length === 0 ? (
            <EmptyState title={squads ? 'No teams registered yet' : 'No players registered yet'}>
              Registered {unit} will appear here.
            </EmptyState>
          ) : (
            <ol className="plist">
              {view.participants.map((p, i) => (
                <li key={i} className="prow">
                  <span className="prow-rank num">{i + 1}</span>
                  <span className="prow-avatar" aria-hidden="true">
                    {participantName(p).charAt(0).toUpperCase()}
                  </span>
                  <span className="prow-main">
                    <span className="prow-name">{participantName(p)}</span>
                    {p.type === 'Squad' && (
                      <span className="prow-members">{p.team.members.join(', ')}</span>
                    )}
                  </span>
                  {canRemove && (
                    <button className="btn-danger prow-remove" onClick={() => setRemoving(p)}>
                      Remove
                    </button>
                  )}
                </li>
              ))}
            </ol>
          )}
        </div>
      )}

      <ConfirmDialog
        open={removing !== null}
        title="Remove participant"
        confirmLabel="Remove"
        danger
        onConfirm={async () => {
          if (removing) {
            await removeParticipant(t.tournamentId, removing)
            await reload()
          }
        }}
        onClose={() => setRemoving(null)}
      >
        <p>
          Remove {removing ? participantName(removing) : ''} from this tournament?{' '}
          {t.requireApproval && removing?.type === 'Individual'
            ? 'If they joined themselves, they will not be able to request to join again unless you approve them.'
            : 'They can register again while registration is open.'}
        </p>
      </ConfirmDialog>

      {view.viewerIsOwner && (
        <OrganizerPanel
          tournament={t}
          bracket={bracket}
          participantCount={view.participants.length}
          registered={view.participants.map(participantName)}
          refreshKey={String(lastUpdated)}
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
    </div>
  )
}