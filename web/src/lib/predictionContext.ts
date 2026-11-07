import { createContext, useContext } from 'react'
import type { PredictionPick } from './predictions'

export type PredictionState = {
  active: boolean // the viewer may predict in this tournament
  canPick: boolean // picks are open (the tournament is running)
  isRoundRobin: boolean // a draw can only be picked in round robin
  picks: ReadonlyMap<number, PredictionPick>
  pick: (matchId: number, pick: PredictionPick) => Promise<void>
}

export const PredictionContext = createContext<PredictionState | null>(null)

export function usePredictions(): PredictionState | null {
  return useContext(PredictionContext)
}
