import { apiVoid, auth } from '../api'

export function saveLobbyCode(matchId: number, code: string) {
  return apiVoid(`/matches/${matchId}/lobby-code`, { method: 'PUT', body: JSON.stringify({ code }) })
}

export function uploadEvidence(matchId: number, image: Blob, note: string) {
  const n = note.trim()
  const q = n === '' ? '' : `?note=${encodeURIComponent(n)}`
  return apiVoid(`/matches/${matchId}/evidence${q}`, {
    method: 'POST',
    body: image,
    headers: { 'Content-Type': 'image/jpeg' },
  })
}

export function removeEvidence(matchId: number, evidenceId: number) {
  return apiVoid(`/matches/${matchId}/evidence/${evidenceId}`, { method: 'DELETE' })
}

export function addReferee(tournamentId: number, username: string) {
  return apiVoid(`/tournaments/${tournamentId}/referees`, {
    method: 'POST',
    body: JSON.stringify({ username }),
  })
}

export function removeReferee(tournamentId: number, userId: number) {
  return apiVoid(`/tournaments/${tournamentId}/referees/${userId}`, { method: 'DELETE' })
}

// Evidence images need the login token, so an <img src> cannot load them directly.
export async function fetchEvidenceBlob(matchId: number, evidenceId: number): Promise<Blob> {
  const token = auth.get()
  const res = await fetch(`/api/matches/${matchId}/evidence/${evidenceId}/image`, {
    headers: token ? { Authorization: `Bearer ${token}` } : {},
  })
  if (!res.ok) throw new Error('Could not load the screenshot')
  return res.blob()
}

// Keeps the aspect ratio, shrinks to at most maxSide pixels and re-encodes as JPEG.
export async function resizeEvidence(file: File, maxSide = 1280): Promise<Blob> {
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, maxSide / Math.max(bitmap.width, bitmap.height))
  const w = Math.max(1, Math.round(bitmap.width * scale))
  const h = Math.max(1, Math.round(bitmap.height * scale))
  const canvas = document.createElement('canvas')
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext('2d')
  if (!ctx) {
    bitmap.close()
    throw new Error('Canvas is not available')
  }
  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, w, h)
  ctx.drawImage(bitmap, 0, 0, w, h)
  bitmap.close()
  const encode = (q: number) =>
    new Promise<Blob>((resolve, reject) => {
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('Could not encode the screenshot'))), 'image/jpeg', q)
    })
  let blob = await encode(0.82)
  if (blob.size > 1_000_000) blob = await encode(0.6)
  return blob
}

export function postMatchMessage(matchId: number, body: string) {
  return apiVoid(`/matches/${matchId}/messages`, { method: 'POST', body: JSON.stringify({ body }) })
}

export function reportGame(matchId: number, gameNo: number, a: number, b: number) {
  return apiVoid(`/matches/${matchId}/games/${gameNo}`, { method: 'PUT', body: JSON.stringify({ a, b }) })
}

export function confirmGame(matchId: number, gameNo: number) {
  return apiVoid(`/matches/${matchId}/games/${gameNo}/confirm`, { method: 'POST' })
}

export function setSeriesLength(tournamentId: number, bestOf: number) {
  return apiVoid(`/tournaments/${tournamentId}/series`, { method: 'PUT', body: JSON.stringify({ bestOf }) })
}
