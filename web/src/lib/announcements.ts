import { z } from 'zod'
import { api, apiVoid } from '../api'

export const AnnouncementRow = z.object({ id: z.number(), body: z.string(), createdAt: z.string() })
export const AnnouncementList = z.object({ announcements: z.array(AnnouncementRow) })
export type AnnouncementItem = z.infer<typeof AnnouncementRow>

export const MAX_ANNOUNCEMENT = 2000

// Owner only. Resolves with the new announcement's id.
export function postAnnouncement(tournamentId: number, body: string) {
  return api(`/tournaments/${tournamentId}/announcements`, z.object({ id: z.number() }), {
    method: 'POST',
    body: JSON.stringify({ body }),
  })
}

// Owner only.
export function deleteAnnouncement(tournamentId: number, id: number) {
  return apiVoid(`/tournaments/${tournamentId}/announcements/${id}`, { method: 'DELETE' })
}