import { api, apiVoid } from '../api'
import { Match, Tournament, RegistrationResult, BracketIdResult, CreateTournamentResponse, CreateTeamResponse, TeamList } from '../model'

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
  participantMode?: 'IndividualOnly' | 'SquadOnly'
  format?: 'SingleElimination' | 'DoubleElimination' | 'RoundRobin'
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