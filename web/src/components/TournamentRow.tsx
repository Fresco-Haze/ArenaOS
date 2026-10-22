import { Link } from 'react-router'
import { statusClass } from '../badges'
import { formatCardDate } from '../lib/cardDate'
import { formatLabel, stateLabel } from '../model'
import type { Tournament } from '../model'
import { CalendarIcon, FormatIcon, PeopleIcon } from './MetaIcons'

export default function TournamentRow({ tournament: t }: { tournament: Tournament }) {
  const mode = t.participantMode === 'SquadOnly' ? 'Squad' : '1v1'
  const when = t.startTime ? formatCardDate(t.startTime) : ''
  return (
    <li className="trow">
      <div className="trow-art" data-game={t.game ?? 'none'} aria-hidden="true" />
      <div className="trow-main">
        <div className="trow-top">
          <h2 className="trow-name">
            <Link to={`/tournaments/${t.tournamentId}`}>{t.name}</Link>
          </h2>
          <span className={'badge ' + statusClass[t.state]}>{stateLabel[t.state]}</span>
        </div>
        <ul className="trow-meta">
          <li><FormatIcon />{mode} &bull; {formatLabel[t.format]}</li>
          {when && <li><CalendarIcon />{when}</li>}
          {t.registeredCount != null && (
            <li><PeopleIcon />{t.registeredCount}/{t.maxParticipants} registered</li>
          )}
        </ul>
      </div>
      <span className="trow-chevron" aria-hidden="true">&rsaquo;</span>
    </li>
  )
}