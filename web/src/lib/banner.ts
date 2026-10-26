import { useSyncExternalStore } from 'react'

// A counter that changes whenever a banner is uploaded or removed, so images reload.
let version = 0
const listeners = new Set<() => void>()

export function bumpBanner() {
  version += 1
  listeners.forEach((l) => l())
}

function subscribe(listener: () => void) {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function useBannerVersion(): number {
  return useSyncExternalStore(subscribe, () => version)
}