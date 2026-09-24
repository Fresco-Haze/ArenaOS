import { z } from 'zod'


export const TournamentState = z.enum([
  'Draft', 'Published', 'RegistrationOpen', 'RegistrationClosed',
  'InProgress', 'Paused', 'Completed', 'Cancelled',
])
export type TournamentState = z.infer<typeof TournamentState>

export const TournamentFormat = z.enum([
  'SingleElimination', 'DoubleElimination', 'RoundRobin',
])
export type TournamentFormat = z.infer<typeof TournamentFormat>

export const Tournament = z.object({
  tournamentId: z.number(),
  name: z.string(),
  organizer: z.string(),
  format: TournamentFormat,
  state: TournamentState,
  visibility: z.enum(['Public', 'Private']),
  maxParticipants: z.number(),
  bracketId: z.number().nullable(),
})
export type Tournament = z.infer<typeof Tournament>

export const Participant = z.discriminatedUnion('type', [
  z.object({ type: z.literal('Individual'), player: z.string() }),
  z.object({
    type: z.literal('Squad'),
    team: z.object({
      name: z.string(),
      captain: z.string(),
      members: z.array(z.string()),
    }),
  }),
])
export type Participant = z.infer<typeof Participant>

export const Slot = z.discriminatedUnion('type', [
  z.object({ type: z.literal('Filled'), participant: Participant }),
  z.object({ type: z.literal('AwaitingWinnerOf'), node: z.number() }),
  z.object({ type: z.literal('AwaitingLoserOf'), node: z.number() }),
  z.object({ type: z.literal('Bye') }),
])
export type Slot = z.infer<typeof Slot>

export const Outcome = z.union([
  z.object({
    type: z.enum(['Winner', 'Forfeit', 'Disqualification']),
    winner: z.enum(['A', 'B']),
  }),
  z.object({ type: z.enum(['Draw', 'NoContest']) }),
])
export type Outcome = z.infer<typeof Outcome>

export const Match = z.object({
  matchId: z.number(),
  tournamentId: z.number(),
  bracketId: z.number(),
  nodeId: z.number(),
  competitorA: Participant,
  competitorB: Participant,
  status: z.enum(['Scheduled', 'InProgress', 'Completed', 'Cancelled']),
  outcome: Outcome.nullable(),
  scheduledStart: z.string().nullable(),
})
export type Match = z.infer<typeof Match>

export const BracketNode = z.object({
  nodeId: z.number(),
  round: z.number(),
  stage: z.enum(['Winners', 'Losers']),
  slotA: Slot,
  slotB: Slot,
  match: Match.nullable(),
})
export type BracketNode = z.infer<typeof BracketNode>

export const BracketView = z.object({
  tournamentId: z.number(),
  format: TournamentFormat,
  bracketId: z.number().nullable(),
  nodes: z.array(BracketNode),
})
export type BracketView = z.infer<typeof BracketView>

export const TournamentView = z.object({
  tournament: Tournament,
  participants: z.array(Participant),
  viewerIsOwner: z.boolean(),
})
export type TournamentView = z.infer<typeof TournamentView>

export const TournamentList = z.object({ tournaments: z.array(Tournament) })

export const LoginResponse = z.object({
  token: z.string(),
  user: z.object({ id: z.number(), username: z.string() }),
})
export type LoginResponse = z.infer<typeof LoginResponse>
export const RegistrationResult = z.object({ registrationId: z.number() })
export const BracketIdResult = z.object({ bracketId: z.number() })

export const stateLabel: Record<TournamentState, string> = {
  Draft: 'Draft',
  Published: 'Published',
  RegistrationOpen: 'Registration open',
  RegistrationClosed: 'Registration closed',
  InProgress: 'In progress',
  Paused: 'Paused',
  Completed: 'Completed',
  Cancelled: 'Cancelled',
}

export const formatLabel: Record<TournamentFormat, string> = {
  SingleElimination: 'Single elimination',
  DoubleElimination: 'Double elimination',
  RoundRobin: 'Round robin',
}

export const RegisterResponse = z.object({
  id: z.number(),
  username: z.string(),
})
export type RegisterResponse = z.infer<typeof RegisterResponse>
export const CreateTournamentResponse = z.object({ tournamentId: z.number() })


