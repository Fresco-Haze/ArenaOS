import { Link } from 'react-router'
import { formatCardDate } from '../lib/cardDate'
import { formatKes } from '../lib/money'
import { formatLabel, gameLabel, stateLabel } from '../model'
import type { Tournament } from '../model'
import { statusClass } from '../badges'

function FormatIcon() {
  return (
    <svg className="meta-icon" viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path d="M2 3.5H6M2 12.5H6M6 3.5V12.5M6 8H14" />
    </svg>
  )
}

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

export default function TournamentCard({ tournament: t, showOrganizer = false }: { tournament: Tournament; showOrganizer?: boolean }) {
  const mode = t.participantMode === 'SquadOnly' ? 'Squad' : '1v1'
  const gameName = t.game && t.game !== 'Other' ? gameLabel[t.game] : null
  const when = t.startTime ? formatCardDate(t.startTime) : ''
  return (
    <li className="tcard">
      <div className="tcard-art" data-game={t.game ?? 'none'}>
        {gameName && <span className="tcard-chip">{gameName}</span>}
        <span className={'badge tcard-status ' + statusClass[t.state]}>{stateLabel[t.state]}</span>
      </div>
      <div className="tcard-body">
        <h2>
          <Link to={`/tournaments/${t.tournamentId}`}>{t.name}</Link>
        </h2>
        <ul className="tcard-meta">
          <li><FormatIcon />{mode}{' \u2022 '}{formatLabel[t.format]}</li>
          {when && <li><CalendarIcon />{when}</li>}
          {t.prize != null && <li className="tcard-prize"><TrophyIcon />{formatKes(t.prize)}</li>}
          {t.registeredCount != null && (
            <li><PeopleIcon />{t.registeredCount}/{t.maxParticipants} registered</li>
          )}
        </ul>
        {showOrganizer && <p className="tcard-organizer">Organized by {t.organizer}</p>}
      </div>
      <span className="tcard-cta" aria-hidden="true">View details &rarr;</span>
    </li>
  )
}