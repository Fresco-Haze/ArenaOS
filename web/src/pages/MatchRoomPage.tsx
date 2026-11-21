import { Link } from 'react-router'
import { useTournament } from '../hooks/useTournament'
import { matchBadge } from '../badges'
import { formatDateTime } from '../lib/dates'
import { participantName } from '../lib/participants'
import type { Participant } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import MatchActions from '../components/MatchActions'
import MatchChat from '../components/MatchChat'
import CheckInCountdown from '../components/CheckInCountdown'
import MatchEvidence from '../components/MatchEvidence'
import MatchLobbyCode from '../components/MatchLobbyCode'
import MatchReferees from '../components/MatchReferees'
import SubstitutionRequests from '../components/SubstitutionRequests'
import MatchSeries from '../components/MatchSeries'
import TeamCrest from '../components/TeamCrest'

const STATUS_LABEL = {
  Scheduled: 'Scheduled',
  InProgress: 'Live',
  Completed: 'Completed',
  Cancelled: 'Cancelled',
} as const

function Side({ p, flip = false }: { p: Participant; flip?: boolean }) {
  const name = participantName(p)
  const crest = <TeamCrest name={name} size={72} team={p.type === 'Squad'} />
  return (
    <div className={'mr-side ' + (flip ? 'mr-side-b' : 'mr-side-a')}>
      {flip ? (
        <>
          {crest}
          <h2>{name}</h2>
        </>
      ) : (
        <>
          <h2>{name}</h2>
          {crest}
        </>
      )}
    </div>
  )
}

function RosterCard({ p, isChecked }: { p: Participant; isChecked: boolean }) {
  const people = p.type === 'Squad' ? p.team.members : []
  return (
    <div className="mr-roster">
      <div className="mr-roster-head">
        <strong>{participantName(p)}</strong>
        <span className={'badge ' + (isChecked ? 'badge-success' : 'badge-neutral')}>
          {isChecked ? 'Checked in' : 'Not checked in'}
        </span>
      </div>
      <ul className="tm-members">
        {people.map((n) => (
          <li key={n}>{n}</li>
        ))}
      </ul>
    </div>
  )
}

export default function MatchRoomPage({ id, nodeId }: { id: string; nodeId: number }) {
  const { state, reload } = useTournament(id)

  if (state.kind === 'loading') return <LoadingBlock label="Loading match" rows={4} />
  if (state.kind === 'notfound') {
    return (
      <EmptyState title="Match not found" action={<Link to="/tournaments">Back to tournaments</Link>}>
        The tournament may not exist, or it may be private.
      </EmptyState>
    )
  }
  if (state.kind === 'error') return <ErrorBanner message={state.message} onRetry={() => void reload()} />

  const { view, bracket, checkIn } = state.data
  const t = view.tournament
  const node = bracket?.nodes.find((n) => n.nodeId === nodeId) ?? null
  const m = node?.match ?? null

  if (!bracket || !node || !m) {
    return (
      <EmptyState title="No match here yet" action={<Link to={`/tournaments/${id}`}>Back to {t.name}</Link>}>
        This match is created once both competitors are known.
      </EmptyState>
    )
  }

  const key = (p: Participant) => p.type + ':' + participantName(p).toLowerCase()
  const checked = new Set((checkIn?.checkedIn ?? []).map(key))
  const roundLabel =
    bracket.format === 'RoundRobin'
      ? null
      : `${node.stage === 'Losers' ? 'Losers' : 'Winners'} bracket \u00b7 Round ${node.round}`

  return (
    <div className="mr">
      <nav aria-label="Breadcrumb" className="tp-crumbs muted">
        <Link to="/tournaments">Tournaments</Link>
        <span aria-hidden="true">&rsaquo;</span>
        <Link to={`/tournaments/${id}`}>{t.name}</Link>
        <span aria-hidden="true">&rsaquo;</span>
        <span>Match room</span>
      </nav>

      <section className="mr-head" aria-label="Match">
        <div className="mr-strip">
          <span className={'badge ' + (matchBadge[m.status] ?? 'badge-neutral')}>{STATUS_LABEL[m.status]}</span>
          {t.game && <span className="muted">{t.game}</span>}
          {roundLabel && <span className="muted">{roundLabel}</span>}
          {m.scheduledStart && m.status === 'Scheduled' && <span className="muted">Starts {formatDateTime(m.scheduledStart)}</span>}
          <span className="mr-ref muted">Organizer: <strong>{t.organizer}</strong></span>
        </div>
        <div className="mr-versus">
          <Side p={m.competitorA} />
          <div className="mr-score" aria-label="Score">
            {node.score ? (
              <><span className="num">{node.score.a}</span><span className="mr-dash">&ndash;</span><span className="num">{node.score.b}</span></>
            ) : (
              <span className="mr-vs">vs</span>
            )}
          </div>
          <Side p={m.competitorB} flip />
        </div>
        <MatchLobbyCode matchId={m.matchId} compact />
      </section>

      <div className="mr-grid">
        <div className="mr-col">
          <section className="pc-card mr-card" aria-labelledby="mr-roster-h">
            <h2 id="mr-roster-h" className="pc-card-head">
              Rosters &amp; check-in
              <span className="muted">
                {[m.competitorA, m.competitorB].filter((p) => checked.has(key(p))).length}/2 checked in{checkIn?.open && checkIn.closesAt ? <> &middot; <CheckInCountdown closesAt={checkIn.closesAt} /></> : null}
              </span>
            </h2>
            {['RegistrationClosed', 'InProgress', 'Paused'].includes(t.state) && (
              <p className="muted mr-lock-note">Rosters are locked. Substitutions need approval from the organizer or a referee.</p>
            )}
            <div className="mr-rosters">
              <RosterCard p={m.competitorA} isChecked={checked.has(key(m.competitorA))} />
              <RosterCard p={m.competitorB} isChecked={checked.has(key(m.competitorB))} />
            </div>
          </section>
          <MatchReferees tournamentId={t.tournamentId} organizer={t.organizer} isOwner={view.viewerIsOwner} />
          <SubstitutionRequests tournamentId={t.tournamentId} />
        </div>

        <div className="mr-col">
          <MatchSeries
            matchId={m.matchId}
            tournamentId={t.tournamentId}
            nameA={participantName(m.competitorA)}
            nameB={participantName(m.competitorB)}
            isOwner={view.viewerIsOwner}
            onSettled={reload}
          />
          <section className="pc-card mr-card" aria-labelledby="mr-actions-h">
            <h2 id="mr-actions-h" className="pc-card-head">{view.viewerIsOwner ? 'Match controls' : 'Match info'}</h2>
            {view.viewerIsOwner ? (
              <MatchActions node={node} format={bracket.format} onDone={reload} />
            ) : (
              <p className="muted">Only the organizer can start this match and report the result.</p>
            )}
          </section>
          <MatchEvidence matchId={m.matchId} />
        </div>

        <div className="mr-col mr-col-chat">
          <MatchChat matchId={m.matchId} />
        </div>
      </div>
    </div>
  )
}