import { useState } from 'react'
import { Link } from 'react-router'
import { statusClass } from '../badges'
import { formatCardDate } from '../lib/cardDate'
import { gameBannerStyle } from '../lib/gameBanners'
import { formatKes } from '../lib/money'
import { formatLabel, gameLabel, stateLabel } from '../model'
import type { Tournament } from '../model'
import BannerImg from './BannerImg'
import Countdown from './Countdown'

// The soonest tournament open for registration; if none has a future start, the newest open one.
export default function DiscoveryHero({ items }: { items: Tournament[] }) {
  const [now] = useState(() => Date.now())
  const open = items.filter((t) => t.state === 'RegistrationOpen')
  const upcoming = open
    .filter((t) => t.startTime && new Date(t.startTime).getTime() > now)
    .sort((a, b) => new Date(a.startTime ?? 0).getTime() - new Date(b.startTime ?? 0).getTime())
  const t = upcoming[0] ?? open.find((x) => x.prize != null || x.startTime) ?? open[0]
  if (!t) return null

  const gameName = t.game && t.game !== 'Other' ? gameLabel[t.game] : null
  const mode = t.participantMode === 'SquadOnly' ? 'Squad' : '1v1'
  const when = t.startTime ? formatCardDate(t.startTime) : ''

  return (
    <section className="dh" aria-labelledby="dh-title">
      <div className="dh-art" data-game={t.game ?? 'none'} style={gameBannerStyle(t.game, t.tournamentId)} aria-hidden="true">
        {t.hasBanner && <BannerImg tournamentId={t.tournamentId} />}
      </div>
      <div className="dh-body">
        <div className="dh-tags">
          <span className={'badge ' + statusClass[t.state]}>{stateLabel[t.state]}</span>
          {gameName && <span className="dh-game">{gameName}</span>}
        </div>
        <h2 id="dh-title" className="dh-title">{t.name}</h2>
        <p className="muted dh-sub">{mode} &bull; {formatLabel[t.format]} &bull; Organized by {t.organizer}</p>
        <dl className="tp-stats">
          {t.prize != null && <div className="tp-stat"><dt>Prize pool</dt><dd className="num">{formatKes(t.prize)}</dd></div>}
          {when && <div className="tp-stat"><dt>Starts</dt><dd>{when}</dd></div>}
          <Countdown to={t.registrationDeadline ?? t.startTime} label={t.registrationDeadline ? 'Closes in' : 'Starts in'} variant="stat" />
          {t.registeredCount != null && (
            <div className="tp-stat"><dt>Slots</dt><dd><span className="num">{t.registeredCount}</span><span className="muted">/{t.maxParticipants}</span></dd></div>
          )}
        </dl>
        <div className="dh-cta">
          <Link to={`/tournaments/${t.tournamentId}`} className="button-link btn-primary">View tournament &rarr;</Link>
        </div>
      </div>
    </section>
  )
}