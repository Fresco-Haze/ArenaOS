import { api, apiVoid } from '../api'
import { Match, Tournament, RegistrationResult, BracketIdResult, CreateTournamentResponse } from '../model'

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

export function recordResult(matchId: number, winner: 'A' | 'B') {
  return api(`/matches/${matchId}/result`, Match, {
    method: 'POST',
    body: JSON.stringify({ type: 'Winner', winner }),
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
}) {
  return api('/tournaments', CreateTournamentResponse, {
    method: 'POST',
    body: JSON.stringify({ ...input, format: 'SingleElimination' }),
  })
}