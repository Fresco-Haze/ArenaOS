import { useState } from 'react'
import { Link } from 'react-router'
import { ApiError } from '../api'

import { statusClass } from '../badges'
import { useAuth } from '../auth/context'
import { useTournament } from '../hooks/useTournament'

import { participantName } from '../lib/participants'
import { formatCardDate } from '../lib/cardDate'
import { formatKes } from '../lib/money'
import { PLATFORMS } from '../lib/details'
import { parseStream } from '../lib/stream'
import { formatLabel, gameLabel, stateLabel, type Participant } from '../model'

import Bracket from '../components/Bracket'
import { gameBannerStyle } from '../lib/gameBanners'
import PredictionProvider from '../components/PredictionProvider'
import PredictionLeaderboard from '../components/PredictionLeaderboard'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import OrganizerPanel from '../components/OrganizerPanel'
import PlayerLookup from '../components/PlayerLookup'
import LobbyStandings from '../components/LobbyStandings'
import Tabs from '../components/Tabs'
import JoinBar from '../components/JoinBar'
import Announcements from '../components/Announcements'
import PrizeSplit from '../components/PrizeSplit'
import { PrizeSplitView } from '../lib/prizeSplit'
import { AnnouncementList } from '../lib/announcements'
import { useApi } from '../hooks/useApi'
import Countdown from '../components/Countdown'
import BannerImg from '../components/BannerImg'
import BannerEditor from '../components/BannerEditor'
import ConfirmDialog from '../components/ConfirmDialog'
import CheckInCountdown from '../components/CheckInCountdown'
import { checkInSelf, removeParticipant, setCheckedIn } from '../lib/tournamentActions'

type TabId = 'overview' | 'bracket' | 'predictions' | 'players' | 'rules' | 'announcements'

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
  const [ckBusy, setCkBusy] = useState(false)
  const [ckError, setCkError] = useState<string | null>(null)
  const ann = useApi(`/tournaments/${id}/announcements`, AnnouncementList, true)
  const annCount = ann.data ? ann.data.announcements.length : 0
  const split = useApi(`/tournaments/${id}/prize-split`, PrizeSplitView, true)
  const [copied, setCopied] = useState(false)

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

  const { view, bracket, checkIn, lastUpdated } = state.data
  const t = view.tournament
  const squads = t.participantMode === 'SquadOnly'
  const unit = squads ? 'teams' : 'players'
  const mode = squads ? 'Squad' : '1v1'
  const gameName = t.game && t.game !== 'Other' ? gameLabel[t.game] : null
  const when = t.startTime ? formatCardDate(t.startTime) : ''
  const slotPct = t.maxParticipants > 0 ? Math.min(100, Math.round((view.participants.length / t.maxParticipants) * 100)) : 0
  const canRemove = view.viewerIsOwner && (t.state === 'RegistrationOpen' || t.state === 'RegistrationClosed')
  const platformName = PLATFORMS.find((p) => p.value === t.platform)?.label ?? null
  const feeText = t.entryFee == null ? null : t.entryFee === 0 ? 'Free' : formatKes(t.entryFee)
  const rulesList = (t.rules ?? '').split('\n').map((r) => r.trim()).filter((r) => r.length > 0)
  // Player profiles are built from public tournaments past Draft, so only link there.
  const profileLinks = t.visibility === 'Public' && t.state !== 'Draft' && t.state !== 'Cancelled'
  const stream = t.streamUrl ? parseStream(t.streamUrl, window.location.hostname) : null
  // Check-in: only while registration is open or closed.
  const checkInPhase = t.state === 'RegistrationOpen' || t.state === 'RegistrationClosed'
  const ckKey = (p: Participant) => p.type + ':' + participantName(p).toLowerCase()
  const checkedNames = new Set((checkIn?.checkedIn ?? []).map(ckKey))
  const checkInInfo = checkIn !== null && (checkIn.open || checkIn.checkedIn.length > 0) ? checkIn : null

  async function copyLink() {
    try {
      await navigator.clipboard.writeText(window.location.href)
      setCopied(true)
      window.setTimeout(() => setCopied(false), 2000)
    } catch {
      setCopied(false)
    }
  }

  async function runCheckIn(action: () => Promise<void>) {
    setCkBusy(true)
    setCkError(null)
    try {
      await action()
      await reload()
    } catch (e) {
      setCkError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setCkBusy(false)
    }
  }
  // Predictions exist for bracket tournaments once the bracket is generated (matches exist).
  const hasPredictions = t.kind === 'Bracket' && ['RegistrationClosed', 'InProgress', 'Paused', 'Completed'].includes(t.state)

  return (
    <div className="tp">
      <nav aria-label="Breadcrumb" className="tp-crumbs muted">
        <Link to="/tournaments">Tournaments</Link>
        <span aria-hidden="true">&rsaquo;</span>
        <span>{t.name}</span>
      </nav>

      <section className="tp-head" aria-labelledby="tp-title">
        <div className="tp-art" data-game={t.game ?? 'none'} style={gameBannerStyle(t.game, t.tournamentId)}>
          <BannerImg tournamentId={t.tournamentId} />
          {view.viewerIsOwner && t.state !== 'Completed' && t.state !== 'Cancelled' && (
            <BannerEditor tournamentId={t.tournamentId} />
          )}
          <span className={'badge tp-status ' + statusClass[t.state]}>{stateLabel[t.state]}</span>
        </div>
        <div className="tp-info">
        <div className="tp-info-main">
          <h1 id="tp-title" className="tp-title">{t.name}</h1>
          <ul className="tp-meta">
            {gameName && <li>{gameName}</li>}
            <li>
              <PeopleIcon />
              {mode} &bull; {(t.kind === 'Lobby' ? 'Lobby' : formatLabel[t.format])}
              {t.thirdPlaceMatch && <> &bull; third-place match</>}
            </li>
            <li>Up to {t.maxParticipants} {unit}</li>
            <li>Organized by {t.organizer}</li>
          </ul>
          <dl className="tp-stats">
            {t.prize != null && <div className="tp-stat"><dt><TrophyIcon />Prize pool</dt><dd className="num">{formatKes(t.prize)}</dd></div>}
            {when && <div className="tp-stat"><dt><CalendarIcon />Starts</dt><dd>{when}</dd></div>}
            {feeText && <div className="tp-stat"><dt>Entry fee</dt><dd>{feeText}</dd></div>}
          </dl>
          {t.registrationDeadline && <p className="muted">Registration closes {formatCardDate(t.registrationDeadline)}</p>}

          </div>
        <div className="tp-info-side">
          <JoinBar tournament={t} signedIn={!!user} registered={view.viewerIsRegistered} requestStatus={view.viewerRequestStatus} onDone={reload} />
          <div className="tp-slots" role="progressbar" aria-valuenow={slotPct} aria-valuemin={0} aria-valuemax={100} aria-label="Slots filled">
            <div className="tp-slots-fill" style={{ width: slotPct + '%' }} />
          </div>
          <p className="muted tp-count">{view.participants.length}/{t.maxParticipants} registered</p>
          <button type="button" className="tp-share" aria-live="polite" onClick={() => void copyLink()}>{copied ? 'Link copied' : 'Copy link'}</button>
          {t.state === 'RegistrationOpen' && (
            <p className="muted tp-closes"><Countdown to={t.registrationDeadline} label="Registration closes in" /></p>
          )}
          {view.viewerIsRegistered && checkIn && checkInPhase && (checkIn.open || checkIn.viewerCheckedIn) && (
            checkIn.viewerCheckedIn ? (
              <p role="status" className="tp-checkin">You&rsquo;re checked in.</p>
            ) : (
              <button className="btn-primary" onClick={() => void runCheckIn(() => checkInSelf(t.tournamentId))} disabled={ckBusy}>
                {ckBusy ? 'Checking in' : 'Check in'}
              </button>
            )
          )}
          {ckError && <p role="alert" className="form-error">{ckError}</p>}
        </div>
        </div>
      </section>

      <Tabs<TabId>
        label="Tournament sections"
        active={tab}
        onChange={setTab}
        tabs={[
          { id: 'overview', label: 'Overview' },
          { id: 'bracket', label: t.kind === 'Lobby' ? 'Standings' : 'Bracket' },
          ...(hasPredictions ? [{ id: 'predictions' as const, label: 'Predictions' }] : []),
          { id: 'players', label: squads ? 'Teams' : 'Players', count: view.participants.length },
          ...(rulesList.length > 0 ? [{ id: 'rules' as const, label: 'Rules' }] : []),
          ...(annCount > 0 || view.viewerIsOwner ? [{ id: 'announcements' as const, label: 'Announcements', count: annCount }] : []),
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
              <li className="tp-tile"><span className="muted">Format</span><strong>{(t.kind === 'Lobby' ? 'Lobby' : formatLabel[t.format])}</strong></li>
              {gameName && <li className="tp-tile"><span className="muted">Game</span><strong>{gameName}</strong></li>}
              <li className="tp-tile"><span className="muted">Mode</span><strong>{squads ? 'Squads' : 'Individual players'}</strong></li>
              {platformName && <li className="tp-tile"><span className="muted">Platform</span><strong>{platformName}</strong></li>}
              {feeText && <li className="tp-tile"><span className="muted">Entry fee</span><strong>{feeText}</strong></li>}
            </ul>
            {stream && (
              <>
                <h3 className="tp-rules-title">Stream</h3>
                {stream.embedUrl && (
                  <div className="tp-stream">
                    <iframe
                      src={stream.embedUrl}
                      title={stream.label + ' stream'}
                      allowFullScreen
                      loading="lazy"
                      referrerPolicy="strict-origin-when-cross-origin"
                    />
                  </div>
                )}
                <p>
                  <a href={stream.url} target="_blank" rel="noopener noreferrer">
                    {stream.embedUrl ? 'Open on ' + stream.label : 'Watch stream'}
                  </a>
                </p>
              </>
            )}
          </section>

          <PrizeSplit
            tournamentId={t.tournamentId}
            prize={t.prize ?? null}
            isOwner={view.viewerIsOwner}
            canEdit={t.state !== 'InProgress' && t.state !== 'Paused' && t.state !== 'Completed' && t.state !== 'Cancelled'}
            data={split.data}
            error={split.error}
            onChanged={split.retry}
          />
          {(t.registrationDeadline || when) && (
            <section className="tp-card tp-schedule">
              <h2 className="tp-section-title">Schedule</h2>
              <ol className="tp-timeline">
                {t.registrationDeadline && (
                  <li><span className="tp-dot" aria-hidden="true" /><div><strong>Registration closes</strong><span className="muted">{formatCardDate(t.registrationDeadline)}</span></div></li>
                )}
                {when && (
                  <li><span className="tp-dot" aria-hidden="true" /><div><strong>Tournament starts</strong><span className="muted">{when}</span></div></li>
                )}
              </ol>
            </section>
          )}
          {checkInInfo && (
            <section className="tp-card tp-checkin-card">
              <h2 className="tp-section-title">Check-in</h2>
              <p className="tp-checkin-count">
                <span className="num">{checkInInfo.checkedIn.length}</span>
                <span className="muted"> of {view.participants.length} checked in</span>
              </p>
              <div className="tp-slots" role="progressbar" aria-valuenow={checkInInfo.checkedIn.length} aria-valuemin={0} aria-valuemax={view.participants.length} aria-label="Checked in">
                <div className="tp-slots-fill" style={{ width: (view.participants.length > 0 ? Math.round((checkInInfo.checkedIn.length / view.participants.length) * 100) : 0) + '%' }} />
              </div>
              <p className="muted">
                {checkInInfo.open ? 'Check-in is open.' : 'Check-in is closed.'}
                {checkInInfo.open && checkInInfo.closesAt ? <> <CheckInCountdown closesAt={checkInInfo.closesAt} /></> : null}
              </p>
            </section>
          )}
        </div>
      ) : tab === 'bracket' && t.kind === 'Lobby' ? (
        <div role="tabpanel" id="panel-bracket" aria-labelledby="tab-bracket">
          <LobbyStandings tournament={t} />
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
            <PredictionProvider tournament={t} viewerIsOwner={view.viewerIsOwner} viewerIsRegistered={view.viewerIsRegistered} bracket={bracket}>
              <Bracket bracket={bracket} tournamentState={t.state} game={t.game} />
            </PredictionProvider>
          ) : (
            <EmptyState title="No bracket yet">
              The bracket appears here once the organizer generates it.
            </EmptyState>
          )}
        </div>
      ) : tab === 'announcements' ? (
        <div role="tabpanel" id="panel-announcements" aria-labelledby="tab-announcements">
          <Announcements tournamentId={t.tournamentId} isOwner={view.viewerIsOwner} items={ann.data ? ann.data.announcements : null} error={ann.error} onChanged={ann.retry} />
        </div>
      ) : tab === 'rules' ? (
        <div role="tabpanel" id="panel-rules" aria-labelledby="tab-rules">
          <section className="tp-card">
            <h2 className="tp-section-title">Rules &amp; format</h2>
            <ul className="tp-rules">
              {rulesList.map((r, i) => (
                <li key={i}>{r}</li>
              ))}
            </ul>
          </section>
        </div>
      ) : tab === 'predictions' && hasPredictions ? (
        <div role="tabpanel" id="panel-predictions" aria-labelledby="tab-predictions">
          <PredictionLeaderboard tournament={t} />
        </div>
      ) : (
        <div role="tabpanel" id="panel-players" aria-labelledby="tab-players">
          <h2 className="tp-section-title">
            Registered {squads ? 'Teams' : 'Players'} ({view.participants.length}/{t.maxParticipants})
            {checkInInfo && (
              <span className="muted"> &middot; {checkInInfo.checkedIn.length} of {view.participants.length} checked in</span>
            )}
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
                    {profileLinks && p.type === 'Individual' ? (
                      <Link className="prow-name prow-link" to={`/players/${encodeURIComponent(p.player)}`}>{p.player}</Link>
                    ) : (
                      <span className="prow-name">{participantName(p)}</span>
                    )}
                    {p.type === 'Squad' && (
                      <span className="prow-members">{p.team.members.join(', ')}</span>
                    )}
                  </span>
                  {checkedNames.has(ckKey(p)) && <span className="badge badge-success prow-checkin">Checked in</span>}
                  {view.viewerIsOwner && checkInPhase && checkIn && (
                    <button
                      className="prow-checkin-btn"
                      onClick={() => void runCheckIn(() => setCheckedIn(t.tournamentId, p, !checkedNames.has(ckKey(p))))}
                      disabled={ckBusy}
                    >
                      {checkedNames.has(ckKey(p)) ? 'Undo check-in' : 'Check in'}
                    </button>
                  )}
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
            : t.state === 'RegistrationClosed'
            ? 'Registration is closed, so they cannot register again.'
            : 'They can register again while registration is open.'}
        </p>
      </ConfirmDialog>

      {view.viewerIsOwner && (
        <OrganizerPanel
          tournament={t}
          bracket={bracket}
          participantCount={view.participants.length}
          checkIn={checkIn}
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