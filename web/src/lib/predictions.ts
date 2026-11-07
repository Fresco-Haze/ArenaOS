import { z } from 'zod'
import { api } from '../api'

export const PredictionPick = z.enum(['A', 'B', 'Draw'])
export type PredictionPick = z.infer<typeof PredictionPick>

export const PredictionList = z.array(
  z.object({
    matchId: z.number(),
    pick: PredictionPick,
    result: z.enum(['correct', 'wrong', 'void', 'pending']),
  }),
)
export type PredictionList = z.infer<typeof PredictionList>

const SavedPrediction = z.object({ saved: z.boolean(), pick: PredictionPick })

export function submitPrediction(matchId: number, pick: PredictionPick) {
  return api(`/matches/${matchId}/prediction`, SavedPrediction, {
    method: 'PUT',
    body: JSON.stringify({ pick }),
  })
}

export const LeaderboardList = z.array(
  z.object({
    rank: z.number(),
    userId: z.number(),
    username: z.string(),
    correct: z.number(),
    wrong: z.number(),
    points: z.number(),
  }),
)
export type LeaderboardList = z.infer<typeof LeaderboardList>
