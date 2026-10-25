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

export function uploadAvatar(image: Blob) {
  return apiVoid('/me/avatar', {
    method: 'PUT',
    body: image,
    headers: { 'Content-Type': 'image/jpeg' },
  })
}

export function removeAvatar() {
  return apiVoid('/me/avatar', { method: 'DELETE' })
}
