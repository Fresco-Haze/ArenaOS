import { z } from 'zod'
import { Participant } from '../model'

// Answers of GET /tournaments/:id/lobby/standings and .../lobby/rounds.
export const LobbyStandingRow = z.object({
  rank: z.number(),
  participantId: z.number(),
  participant: Participant,
  points: z.number(),
  kills: z.number(),
  bestPlacement: z.number().nullable(),
  roundsPlayed: z.number(),
})

export const LobbyStandingsView = z.object({
  standings: z.array(LobbyStandingRow),
  championParticipantId: z.number().nullable(),
})
export type LobbyStandingsView = z.infer<typeof LobbyStandingsView>

export const LobbyRoundsView = z.object({
  rounds: z.array(
    z.object({
      round: z.number(),
      results: z.array(z.object({ participantId: z.number(), placement: z.number(), kills: z.number() })),
    }),
  ),
})
export type LobbyRoundsView = z.infer<typeof LobbyRoundsView>
