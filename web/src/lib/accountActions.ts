import { apiVoid } from '../api'

export function changePassword(currentPassword: string, newPassword: string) {
  return apiVoid('/me/password', {
    method: 'POST',
    body: JSON.stringify({ currentPassword, newPassword }),
  })
}

export function saveFullName(fullName: string | null) {
  return apiVoid('/me/profile', {
    method: 'PUT',
    body: JSON.stringify({ fullName }),
  })
}