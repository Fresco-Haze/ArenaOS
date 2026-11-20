export type Recruitment = 'OpenTryouts' | 'InviteOnly'

export type ProfileDraft = { tag: string; game: string; region: string; recruitment: Recruitment }

export const EMPTY_PROFILE: ProfileDraft = { tag: '', game: '', region: '', recruitment: 'InviteOnly' }

export const REGIONS = [
  'NA East', 'NA West', 'EU West', 'EU Nordic',
  'South America', 'Oceania', 'Southeast Asia', 'Middle East',
]

export const RECRUITMENT_LABEL: Record<Recruitment, string> = {
  OpenTryouts: 'Open to tryouts',
  InviteOnly: 'Invite only',
}