import { api } from '../api'
import { RegisterResponse } from '../model'

export function registerUser(username: string, email: string, password: string) {
  return api('/register', RegisterResponse, {
    method: 'POST',
    body: JSON.stringify({ username, email, password }),
  })
}