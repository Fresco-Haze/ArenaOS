import type { TournamentState } from './model'

export const stateBadge: Record<TournamentState, string> = {
  Draft: 'badge-neutral',
  Published: 'badge-neutral',
  RegistrationOpen: 'badge-info',
  RegistrationClosed: 'badge-neutral',
  InProgress: 'badge-info',
  Paused: 'badge-warning',
  Completed: 'badge-success',
  Cancelled: 'badge-danger',
}

export const matchBadge: Record<string, string> = {
  Scheduled: 'badge-neutral',
  InProgress: 'badge-info',
  Completed: 'badge-success',
  Cancelled: 'badge-danger',
}

// Pill colours used on tournament cards and the tournament page header.
export const statusClass: Record<TournamentState, string> = {
  Draft: 'status-neutral',
  Published: 'status-neutral',
  RegistrationOpen: 'status-open',
  RegistrationClosed: 'status-neutral',
  InProgress: 'status-live',
  Paused: 'status-warning',
  Completed: 'status-done',
  Cancelled: 'status-danger',
}