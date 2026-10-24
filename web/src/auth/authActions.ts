import { api, apiVoid } from '../api'
import { RegisterResponse } from '../model'

export function registerUser(username: string, email: string, password: string, fullName?: string) {
  return api('/register', RegisterResponse, {
    method: 'POST',
    body: JSON.stringify({ username, email, password, ...(fullName ? { fullName } : {}) }),
  })
}

// Always succeeds from the user's point of view, whether or not the email has an account.
export function requestPasswordReset(email: string) {
  return apiVoid('/forgot-password', {
    method: 'POST',
    body: JSON.stringify({ email }),
  })
}

export function resetPassword(token: string, password: string) {
  return apiVoid('/reset-password', {
    method: 'POST',
    body: JSON.stringify({ token, password }),
  })
}