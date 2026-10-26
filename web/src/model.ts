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

export const ParticipantMode = z.enum(['IndividualOnly', 'SquadOnly'])
export type ParticipantMode = z.infer<typeof ParticipantMode>

export const Game = z.enum(['eFootball', 'PubgMobile', 'CallOfDuty', 'Other'])
export type Game = z.infer<typeof Game>

export const Tournament = z.object({
  tournamentId: z.number(),
  name: z.string(),
  organizer: z.string(),
  format: TournamentFormat,
  state: TournamentState,
  visibility: z.enum(['Public', 'Private']),
  maxParticipants: z.number(),
  thirdPlaceMatch: z.boolean(),
  requireApproval: z.boolean().default(false),
  participantMode: ParticipantMode,
  game: Game.nullish(),
  startTime: z.string().nullish(),
  registrationDeadline: z.string().nullish(),
  entryFee: z.number().nullish(),
  platform: z.string().nullish(),
  rules: z.string().nullish(),
  prize: z.number().nullish(),
  description: z.string().nullish(),
  registeredCount: z.number().nullish(),
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

export const NodeLink = z.object({ node: z.number(), slot: z.enum(['A', 'B']) })
export type NodeLink = z.infer<typeof NodeLink>

export const BracketNode = z.object({
  nodeId: z.number(),
  round: z.number(),
  stage: z.enum(['Winners', 'Losers']),
  slotA: Slot,
  slotB: Slot,
  match: Match.nullable(),
  score: z.object({ a: z.number(), b: z.number() }).nullish(),
  winnerTo: NodeLink.nullish(),
  loserTo: NodeLink.nullish(),
})
export type BracketNode = z.infer<typeof BracketNode>

export const BracketView = z.object({
  tournamentId: z.number(),
  format: TournamentFormat,
  bracketId: z.number().nullable(),
  thirdPlaceNodeId: z.number().nullable(),
  grandFinalNodeId: z.number().nullish(),
  resetNodeId: z.number().nullish(),
  linksAvailable: z.boolean().nullish(),
  standings: z.array(z.object({ participant: Participant, points: z.number(), goalsFor: z.number().default(0), goalsAgainst: z.number().default(0), goalDifference: z.number().default(0) })).nullish(),
  unscoredMatches: z.number().nullish(),
  nodes: z.array(BracketNode),
})
export type BracketView = z.infer<typeof BracketView>

export const TournamentView = z.object({
  tournament: Tournament,
  participants: z.array(Participant),
  viewerIsOwner: z.boolean(),
  viewerIsRegistered: z.boolean().default(false),
  viewerRequestStatus: z.enum(['Pending', 'Approved', 'Declined']).nullish(),
})
export type TournamentView = z.infer<typeof TournamentView>

export const JoinRequestStatus = z.enum(['Pending', 'Approved', 'Declined'])
export type JoinRequestStatus = z.infer<typeof JoinRequestStatus>
export const JoinRequestRow = z.object({
  userId: z.number(),
  username: z.string(),
  status: JoinRequestStatus,
})
export type JoinRequestRow = z.infer<typeof JoinRequestRow>
export const JoinRequestList = z.object({ requests: z.array(JoinRequestRow) })

export const TournamentList = z.object({ tournaments: z.array(Tournament) })

export const ActivityItem = z.object({
  tournamentId: z.number(),
  name: z.string(),
  event: z.enum(['Published', 'RegistrationOpened', 'Started', 'Completed', 'Cancelled', 'Reopened', 'Other']),
  at: z.string(),
})
export type ActivityItem = z.infer<typeof ActivityItem>
export const ActivityList = z.object({ activity: z.array(ActivityItem) })

export const RankingRow = z.object({ rank: z.number(), player: z.string(), titles: z.number(), wins: z.number() })
export const RankingList = z.object({ rankings: z.array(RankingRow) })

export const MeProfile = z.object({
  email: z.string(),
  bio: z.string().nullish(),
  memberSince: z.string().nullish(),
})

export const PlayerRow = z.object({ name: z.string(), tournaments: z.number(), titles: z.number(), wins: z.number() })
export const PlayerList = z.object({ players: z.array(PlayerRow) })
export const PlayerProfileView = z.object({
  name: z.string(),
  tournaments: z.number(),
  titles: z.number(),
  wins: z.number(),
  history: z.array(z.object({ tournament: Tournament, champion: z.boolean() })),
})
export type PlayerProfileView = z.infer<typeof PlayerProfileView>

export const NotificationItem = z.object({
  id: z.number(),
  kind: z.enum(['JoinRequested', 'RequestApproved', 'RequestDeclined', 'TournamentStarted']),
  tournamentId: z.number(),
  tournamentName: z.string(),
  detail: z.string().nullish(),
  at: z.string(),
  read: z.boolean(),
})
export type NotificationItem = z.infer<typeof NotificationItem>
export const NotificationList = z.object({
  unread: z.number(),
  notifications: z.array(NotificationItem),
})
export type NotificationList = z.infer<typeof NotificationList>

export const LoginResponse = z.object({
  token: z.string(),
  user: z.object({ hasAvatar: z.boolean().default(false), id: z.number(), username: z.string(), fullName: z.string().nullish() }),
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



export const Team = z.object({
  name: z.string(),
  captain: z.string(),
  members: z.array(z.string()),
})
export type Team = z.infer<typeof Team>
export const CreateTeamResponse = Team
export const TeamList = z.object({ teams: z.array(Team) })

export const gameLabel: Record<Game, string> = {
  eFootball: 'eFootball',
  PubgMobile: 'PUBG Mobile',
  CallOfDuty: 'Call of Duty',
  Other: 'Other',
}

export const PublicStatsView = z.object({
  tournaments: z.number(),
  activeTournaments: z.number(),
  players: z.number(),
  teams: z.number(),
  prizePool: z.number(),
  byGame: z.array(z.object({ game: Game, count: z.number() })),
})
export type PublicStatsView = z.infer<typeof PublicStatsView>

export const MyMatchSummary = z.object({
  nextMatch: z
    .object({ tournamentId: z.number(), tournamentName: z.string(), match: Match })
    .nullable(),
  tournamentsWon: z.number(),
})
export type MyMatchSummary = z.infer<typeof MyMatchSummary>