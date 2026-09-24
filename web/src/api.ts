import type { ZodType } from 'zod'

const TOKEN_KEY = 'arenaos.token'

type Listener = () => void
const expiredListeners = new Set<Listener>()

export const auth = {
  get: () => localStorage.getItem(TOKEN_KEY),
  set: (token: string) => localStorage.setItem(TOKEN_KEY, token),
  clear: () => localStorage.removeItem(TOKEN_KEY),
  // AuthContext registers here so api.ts can say "the session died"
  // without knowing anything about React.
  onSessionExpired: (fn: Listener) => {
    expiredListeners.add(fn)
    return () => {
      expiredListeners.delete(fn)
    }
  },
}

export class ApiError extends Error {
  status: number
  code: string
  details: unknown

  constructor(status: number, code: string, message: string, details: unknown) {
    super(message)
    this.status = status
    this.code = code
    this.details = details
  }
}

type Options = RequestInit & {
  // For public reads: if the token turns out to be dead, retry once without it.
  retryAnonymously?: boolean
}

async function request(path: string, options: Options): Promise<Response> {
  const { retryAnonymously, ...init } = options
  const headers = new Headers(init.headers)
  const token = auth.get()
  if (token) headers.set('Authorization', `Bearer ${token}`)
  if (init.body) headers.set('Content-Type', 'application/json')

  let res: Response
  try {
    res = await fetch(`/api${path}`, { ...init, headers })
  } catch {
    throw new ApiError(0, 'NETWORK', 'Could not reach the server', undefined)
  }
  if (res.ok) return res

  const data = await res.json().catch(() => null)
  const e = data?.error
  const code: string = e?.code ?? 'UNKNOWN'

  // Only a token we actually sent can expire. A wrong password on /login is
  // also a 401, but its code is INVALID_CREDENTIALS and it signs nobody out.
  if (res.status === 401 && code === 'UNAUTHENTICATED' && token) {
    auth.clear()
    expiredListeners.forEach((fn) => fn())
    // The token is gone now, so this second attempt is sent anonymously.
    if (retryAnonymously) return request(path, init)
  }

  throw new ApiError(
    res.status,
    code,
    e?.message ?? (res.status >= 500 ? 'The server is not responding' : 'Request failed'),
    e?.details,
  )
}

// For endpoints that return a JSON body: validated against a schema.
export async function api<T>(path: string, schema: ZodType<T>, options: Options = {}): Promise<T> {
  const res = await request(path, options)
  const parsed = schema.safeParse(await res.json().catch(() => null))
  if (!parsed.success) {
    console.error('Unexpected response from', path, parsed.error.issues)
    throw new ApiError(res.status, 'BAD_RESPONSE',
      'The server sent an unexpected response', parsed.error.issues)
  }
  return parsed.data
}

// For endpoints that answer 204 No Content.
export async function apiVoid(path: string, options: Options = {}): Promise<void> {
  await request(path, options)
}