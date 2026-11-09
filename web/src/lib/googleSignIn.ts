import { z } from 'zod'
import { api } from '../api'
import { LoginResponse } from '../model'
import { safeNext } from './safeNext'

const NEXT_KEY = 'arenaos.googleNext'

const Providers = z.object({ google: z.boolean() })

export function fetchProviders() {
  return api('/auth/providers', Providers)
}

// Remember where to go after sign-in, then leave for Google. The API sets a
// state cookie and redirects; the way back ends on /login/google.
export function startGoogle(next: string) {
  try {
    sessionStorage.setItem(NEXT_KEY, next)
  } catch {
    // Storage can be blocked. Sign-in still works; the person lands on the home page.
  }
  window.location.assign('/api/auth/google/start')
}

// Reading does not clear it, so a repeated render (StrictMode) cannot lose it.
export function peekGoogleNext(): string {
  try {
    return safeNext(sessionStorage.getItem(NEXT_KEY))
  } catch {
    return '/'
  }
}

export function clearGoogleNext() {
  try {
    sessionStorage.removeItem(NEXT_KEY)
  } catch {
    // Nothing to clear.
  }
}

export function finishGoogle(code: string, username?: string, ageConfirmed?: boolean) {
  const body: Record<string, unknown> = { code }
  if (username !== undefined) body.username = username
  if (ageConfirmed) body.ageConfirmed = true
  return api('/auth/google/finish', LoginResponse, { method: 'POST', body: JSON.stringify(body) })
}

// A code works once. In development React runs effects twice, so the second
// run must reuse the first call instead of sending the code again.
const inflight = new Map<string, ReturnType<typeof finishGoogle>>()
export function finishLoginOnce(code: string) {
  let p = inflight.get(code)
  if (!p) {
    p = finishGoogle(code)
    inflight.set(code, p)
  }
  return p
}

// When a sign-up attempt fails, the server sends a fresh code (retryCode) and,
// when the problem is about one field, the field name (inside info).
export function retryInfo(details: unknown): { retryCode: string | null; field: string | null } {
  if (!details || typeof details !== 'object') return { retryCode: null, field: null }
  const d = details as { retryCode?: unknown; info?: unknown }
  const retryCode = typeof d.retryCode === 'string' ? d.retryCode : null
  const info = d.info && typeof d.info === 'object' ? (d.info as { field?: unknown }) : null
  const field = info && typeof info.field === 'string' ? info.field : null
  return { retryCode, field }
}

const GENERIC = 'Google sign-in did not work. Please try again.'
const MESSAGES: Record<string, string> = {
  email_in_use: 'That email already has an account. Sign in with your password instead.',
  email_not_verified: 'Google says that email address is not verified, so it cannot be used here.',
  account_not_active: 'This account cannot sign in right now.',
  google_denied: 'Google sign-in was cancelled.',
  too_many: 'Too many attempts. Please try again later.',
  state: 'The sign-in could not be checked. Please try again.',
  google_failed: GENERIC,
}

// Turns the ?error= code from /login into a message. Unknown codes get the generic one.
export function googleErrorMessage(code: string | null): string | null {
  if (!code) return null
  return Object.hasOwn(MESSAGES, code) ? MESSAGES[code] : GENERIC
}