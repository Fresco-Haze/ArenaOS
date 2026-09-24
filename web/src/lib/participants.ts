import type { Participant } from '../model'

export function participantName(p: Participant): string {
  return p.type === 'Individual' ? p.player : p.team.name
}