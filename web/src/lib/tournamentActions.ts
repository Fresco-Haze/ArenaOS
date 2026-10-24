import { api, apiVoid } from '../api'
import { Match, Tournament, RegistrationResult, BracketIdResult, CreateTournamentResponse, CreateTeamResponse, TeamList, JoinRequestList, NotificationList, type Game, type Participant, type TournamentFormat } from '../model'

export function publish(id: number) {
  return apiVoid(`/tournaments/${id}/publish`, { method: 'POST' })
}

export function openRegistration(id: number) {
  return apiVoid(`/tournaments/${id}/open-registration`, { method: 'POST' })
}

export function addParticipant(id: number, playerName: string) {
  return api(`/tournaments/${id}/registrations`, RegistrationResult, {
    method: 'POST',
    body: JSON.stringify({ type: 'Individual', player: playerName }),
  })
}

export function closeRegistration(id: number) {
  return apiVoid(`/tournaments/${id}/close-registration`, { method: 'POST' })
}

export function generateBracket(id: number) {
  return api(`/tournaments/${id}/bracket`, BracketIdResult, { method: 'POST' })
}

export function startTournament(id: number) {
  return apiVoid(`/tournaments/${id}/start`, { method: 'POST' })
}

export function startMatch(matchId: number) {
  return api(`/matches/${matchId}/start`, Match, { method: 'POST' })
}

export function recordResult(
  matchId: number,
  outcome: { type: 'Winner' | 'Forfeit' | 'Disqualification'; winner: 'A' | 'B' } | { type: 'Draw' | 'NoContest' },
) {
  return api(`/matches/${matchId}/result`, Match, {
    method: 'POST',
    body: JSON.stringify(outcome),
  })
}

export function completeTournament(id: number) {
  return api(`/tournaments/${id}/complete`, Tournament, { method: 'POST' })
}

export function cancelTournament(id: number, reason: string) {
  return apiVoid(`/tournaments/${id}/cancel`, {
    method: 'POST',
    body: JSON.stringify({ reason }),
  })
}

export function createTournament(input: {
  name: string
  organizer: string
  visibility: 'Public' | 'Private'
  maxParticipants: number
  thirdPlaceMatch: boolean
  requireApproval?: boolean
  participantMode?: 'IndividualOnly' | 'SquadOnly'
  format?: 'SingleElimination' | 'DoubleElimination' | 'RoundRobin'
  game?: Game | null
  startTime?: string | null
  prize?: number | null
  description?: string | null
  registrationDeadline?: string | null
}) {
  return api('/tournaments', CreateTournamentResponse, {
    method: 'POST',
    body: JSON.stringify({ ...input, format: input.format ?? 'SingleElimination' }),
  })
}

export function updateName(id: number, name: string) {
  return apiVoid(`/tournaments/${id}/name`, {
    method: 'PUT',
    body: JSON.stringify({ name }),
  })
}

export function updateVisibility(id: number, visibility: 'Public' | 'Private') {
  return apiVoid(`/tournaments/${id}/visibility`, {
    method: 'PUT',
    body: JSON.stringify({ visibility }),
  })
}

export function updateMaxParticipants(id: number, maxParticipants: number) {
  return apiVoid(`/tournaments/${id}/max-participants`, {
    method: 'PUT',
    body: JSON.stringify({ maxParticipants }),
  })
}

export function pauseTournament(id: number) {
  return apiVoid(`/tournaments/${id}/pause`, { method: 'POST' })
}

export function resumeTournament(id: number) {
  return apiVoid(`/tournaments/${id}/resume`, { method: 'POST' })
}

export function reopenTournament(id: number, reason: string) {
  return apiVoid(`/tournaments/${id}/reopen`, {
    method: 'POST',
    body: JSON.stringify({ reason }),
  })
}

export function setThirdPlaceMatch(id: number, enabled: boolean) {
  return apiVoid(`/tournaments/${id}/third-place-match`, {
    method: 'POST',
    body: JSON.stringify({ thirdPlaceMatch: enabled }),
  })
}

export function setRequireApproval(id: number, enabled: boolean) {
  return apiVoid(`/tournaments/${id}/require-approval`, {
    method: 'POST',
    body: JSON.stringify({ requireApproval: enabled }),
  })
}

export function updateFormat(id: number, format: TournamentFormat) {
  return apiVoid(`/tournaments/${id}/format`, {
    method: 'PUT',
    body: JSON.stringify({ format }),
  })
}

export function recordEFootballResult(matchId: number, scoreA: number, scoreB: number) {
  return api(`/matches/${matchId}/efootball-result`, Match, {
    method: 'POST',
    body: JSON.stringify({ scoreA, scoreB }),
  })
}

export function correctResult(
  matchId: number,
  outcome: { type: 'Winner' | 'Forfeit' | 'Disqualification'; winner: 'A' | 'B' } | { type: 'Draw' | 'NoContest' },
) {
  return api(`/matches/${matchId}/result`, Match, {
    method: 'PUT',
    body: JSON.stringify(outcome),
  })
}

export function correctEFootballResult(matchId: number, scoreA: number, scoreB: number) {
  return api(`/matches/${matchId}/efootball-result`, Match, {
    method: 'PUT',
    body: JSON.stringify({ scoreA, scoreB }),
  })
}

export function setSchedule(matchId: number, start: string | null) {
  return api(`/matches/${matchId}/schedule`, Match, {
    method: 'PUT',
    body: JSON.stringify({ start }),
  })
}

export function registerSquad(id: number, teamName: string) {
  return api(`/tournaments/${id}/registrations`, RegistrationResult, {
    method: 'POST',
    body: JSON.stringify({ type: 'Squad', teamName }),
  })
}

export function listTeams() {
  return api('/teams', TeamList)
}

export function createTeam(input: { name: string; captain: string; members: string[] }) {
  return api('/teams', CreateTeamResponse, {
    method: 'POST',
    body: JSON.stringify(input),
  })
}

// Replaces game, start time and prize; null clears a field.
export function updateDetails(
  id: number,
  details: { game: Game | null; startTime: string | null; registrationDeadline: string | null; prize: number | null; description: string | null },
) {
  return apiVoid(`/tournaments/${id}/details`, {
    method: 'PUT',
    body: JSON.stringify(details),
  })
}

// Self-registration: the signed-in user joins or leaves an open tournament.
export function joinTournament(id: number) {
  return apiVoid(`/tournaments/${id}/join`, { method: 'POST' })
}

export function withdrawFromTournament(id: number) {
  return apiVoid(`/tournaments/${id}/withdraw`, { method: 'POST' })
}

export function removeParticipant(id: number, p: Participant) {
  const body = p.type === 'Squad'
    ? { type: 'Squad', teamName: p.team.name }
    : { type: 'Individual', player: p.player }
  return apiVoid(`/tournaments/${id}/registrations/remove`, {
    method: 'POST',
    body: JSON.stringify(body),
  })
}

export function cancelJoinRequest(id: number) {
  return apiVoid(`/tournaments/${id}/cancel-request`, { method: 'POST' })
}

export function listJoinRequests(id: number) {
  return api(`/tournaments/${id}/requests`, JoinRequestList)
}

export function approveJoinRequest(id: number, userId: number) {
  return apiVoid(`/tournaments/${id}/requests/approve`, {
    method: 'POST',
    body: JSON.stringify({ userId }),
  })
}

export function declineJoinRequest(id: number, userId: number) {
  return apiVoid(`/tournaments/${id}/requests/decline`, {
    method: 'POST',
    body: JSON.stringify({ userId }),
  })
}

export function fetchNotifications() {
  return api('/me/notifications', NotificationList)
}

export function markNotificationsRead() {
  return apiVoid('/me/notifications/read', { method: 'POST' })
}
