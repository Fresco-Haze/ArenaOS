import { apiVoid } from '../api'

export function uploadTeamLogo(teamName: string, image: Blob) {
  return apiVoid(`/teams/${encodeURIComponent(teamName)}/logo`, {
    method: 'PUT',
    body: image,
    headers: { 'Content-Type': 'image/jpeg' },
  })
}

export function removeTeamLogo(teamName: string) {
  return apiVoid(`/teams/${encodeURIComponent(teamName)}/logo`, { method: 'DELETE' })
}

export function inviteToTeam(teamName: string, username: string) {
  return apiVoid(`/teams/${encodeURIComponent(teamName)}/invites`, {
    method: 'POST',
    body: JSON.stringify({ username }),
  })
}

export function revokeTeamInvite(teamName: string, userId: number) {
  return apiVoid(`/teams/${encodeURIComponent(teamName)}/invites/${userId}`, { method: 'DELETE' })
}

export function acceptTeamInvite(team: string) {
  return apiVoid('/me/team-invites/accept', { method: 'POST', body: JSON.stringify({ team }) })
}

export function declineTeamInvite(team: string) {
  return apiVoid('/me/team-invites/decline', { method: 'POST', body: JSON.stringify({ team }) })
}

export function saveTeamProfile(
  teamName: string,
  profile: { tag: string; game: string; region: string; recruitment: 'OpenTryouts' | 'InviteOnly' },
) {
  return apiVoid(`/teams/${encodeURIComponent(teamName)}/profile`, {
    method: 'PUT',
    body: JSON.stringify(profile),
  })
}

export function requestSubstitution(teamName: string, input: { tournamentId: number; out: string; incoming: string }) {
  return apiVoid(`/teams/${encodeURIComponent(teamName)}/substitutions`, {
    method: 'POST',
    body: JSON.stringify(input),
  })
}

export function decideSubstitution(tournamentId: number, id: number, approve: boolean) {
  return apiVoid(`/tournaments/${tournamentId}/substitutions/${id}/${approve ? 'approve' : 'decline'}`, { method: 'POST' })
}
