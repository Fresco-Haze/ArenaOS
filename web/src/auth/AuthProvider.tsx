import { useEffect, useState } from 'react'
import type { ReactNode } from 'react'
import { api, apiVoid, auth } from '../api'
import { LoginResponse } from '../model'
import { AuthContext } from './context'
import type { SessionUser } from './context'

const USER_KEY = 'arenaos.user'

function clearStoredUser() {
  localStorage.removeItem(USER_KEY)
  sessionStorage.removeItem(USER_KEY)
}

function loadUser(): SessionUser | null {
  if (!auth.get()) return null
  try {
    const raw = localStorage.getItem(USER_KEY) ?? sessionStorage.getItem(USER_KEY)
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
  const [avatarVersion, setAvatarVersion] = useState(0)

  useEffect(() => {
    // api.ts calls this when the server says a token we sent is dead.
    return auth.onSessionExpired(() => {
      clearStoredUser()
      setUser(null)
      setExpired(true)
    })
  }, [])

  async function login(username: string, password: string, remember = true) {
    const res = await api('/login', LoginResponse, {
      method: 'POST',
      body: JSON.stringify({ identifier: username, password }),
    })
    auth.set(res.token, remember)
    clearStoredUser()
    if (remember) localStorage.setItem(USER_KEY, JSON.stringify(res.user))
    else sessionStorage.setItem(USER_KEY, JSON.stringify(res.user))
    setUser(res.user)
    setExpired(false)
  }

  function updateFullName(name: SessionUser['fullName']) {
    if (!user) return
    const next = { ...user, fullName: name }
    const store = localStorage.getItem(USER_KEY) !== null ? localStorage : sessionStorage
    store.setItem(USER_KEY, JSON.stringify(next))
    setUser(next)
  }

  function setHasAvatar(has: boolean) {
    if (!user) return
    const next = { ...user, hasAvatar: has }
    const store = localStorage.getItem(USER_KEY) !== null ? localStorage : sessionStorage
    store.setItem(USER_KEY, JSON.stringify(next))
    setUser(next)
    setAvatarVersion((v) => v + 1)
  }

  async function logout() {
    try {
      await apiVoid('/logout', { method: 'POST' })
    } catch {
      // The local session ends whether or not the server answered.
    }
    auth.clear()
    clearStoredUser()
    setUser(null)
    setExpired(false)
  }

  return (
    <AuthContext.Provider
      value={{ user, expired, dismissExpired: () => setExpired(false), login, logout, updateFullName, setHasAvatar, avatarVersion }}
    >
      {children}
    </AuthContext.Provider>
  )
}