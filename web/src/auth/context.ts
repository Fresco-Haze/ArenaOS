import { createContext, useContext } from 'react'
import type { LoginResponse } from '../model'

export type SessionUser = LoginResponse['user']

export type AuthValue = {
  user: SessionUser | null
  expired: boolean
  dismissExpired: () => void
  login: (username: string, password: string) => Promise<void>
  logout: () => Promise<void>
}

export const AuthContext = createContext<AuthValue | null>(null)

export function useAuth(): AuthValue {
  const value = useContext(AuthContext)
  if (!value) throw new Error('useAuth must be used inside <AuthProvider>')
  return value
}