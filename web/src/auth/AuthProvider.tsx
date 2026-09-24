import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { api, apiVoid, auth } from '../api'
import { LoginResponse } from '../model'
import { AuthContext } from './context'
import type { SessionUser } from './context'

const USER_KEY = 'arenaos.user'

function loadUser(): SessionUser | null {
  if (!auth.get()) return null
  try {
    const raw = localStorage.getItem(USER_KEY)
    if (!raw) return null
    const parsed = LoginResponse.shape.user.safeParse(JSON.parse(raw))
    return parsed.success ? parsed.data : null
  } catch {
    return null
  }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<SessionUser | null>(loadUser)
  const [expired, setExpired] = useState(false)

  useEffect(() => {
    // api.ts calls this when the server says a token we sent is dead.
    return auth.onSessionExpired(() => {
      localStorage.removeItem(USER_KEY)
      setUser(null)
      setExpired(true)
    })
  }, [])

  async function login(username: string, password: string) {
    const res = await api('/login', LoginResponse, {
      method: 'POST',
      body: JSON.stringify({ username, password }),
    })
    auth.set(res.token)
    localStorage.setItem(USER_KEY, JSON.stringify(res.user))
    setUser(res.user)
    setExpired(false)
  }

  async function logout() {
    try {
      await apiVoid('/logout', { method: 'POST' })
    } catch {
      // The local session ends whether or not the server answered.
    }
    auth.clear()
    localStorage.removeItem(USER_KEY)
    setUser(null)
    setExpired(false)
  }

  return (
    <AuthContext.Provider
      value={{ user, expired, dismissExpired: () => setExpired(false), login, logout }}
    >
      {children}
    </AuthContext.Provider>
  )
}