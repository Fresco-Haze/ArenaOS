import { Link } from 'react-router'
import { stateBadge } from '../badges'
import { formatLabel, stateLabel } from '../model'
import type { Tournament } from '../model'

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

export default function TournamentCard({ tournament: t, showOrganizer = false }: { tournament: Tournament; showOrganizer?: boolean }) {
  const unit = t.participantMode === 'SquadOnly' ? 'teams' : 'players'
  return (
    <li className="card tournament-card">
      <div className="card-title-row">
        <h2>
          <Link to={`/tournaments/${t.tournamentId}`}>{t.name}</Link>
        </h2>
        <span className={'badge ' + stateBadge[t.state]}>{stateLabel[t.state]}</span>
      </div>
      <p className="card-meta">
        <span className="card-meta-item"><FormatIcon />{formatLabel[t.format]}</span>
        <span className="card-meta-item"><PeopleIcon />Up to {t.maxParticipants} {unit}</span>
      </p>
      {showOrganizer && <p className="meta">Organized by {t.organizer}</p>}
    </li>
  )
}