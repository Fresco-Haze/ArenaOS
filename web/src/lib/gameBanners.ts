import type { CSSProperties } from 'react'

// Which games have banner images in public/art/games, and how many variants each has.
// A game's images are <slug>.jpg, <slug>-2.jpg and <slug>-3.jpg. Written by the import script.
const BANNERS: Readonly<Record<string, number>> = {
  'apex-legends': 1,
  'badminton': 2,
  'beer-pong': 2,
  'bgmi': 3,
  'checkers': 1,
  'chess': 1,
  'clash-of-clans': 1,
  'clash-royale': 1,
  'cornhole': 2,
  'counter-strike-2': 1,
  'dota-2': 1,
  'ea-sports-fc': 1,
  'f1': 1,
  'fifa': 3,
  'gran-turismo': 1,
  'guilty-gear-strive': 2,
  'halo': 1,
  'league-of-legends': 2,
  'madden-nfl': 2,
  'magic-the-gathering': 2,
  'mario-kart': 2,
  'mobile-legends-bang-bang': 2,
  'mortal-kombat-1': 1,
  'nba-2k': 1,
  'pickleball': 1,
  'rainbow-six-siege': 1,
  'dragon-ball-fighterz': 1,
  'fortnite': 1,
  'overwatch-2': 1,
  'padel': 1,
  'pokemon-tcg': 1,
  'rocket-league': 1,
  'street-fighter-6': 1,
  'super-smash-bros': 1,
  'teamfight-tactics': 1,
  'tekken-8': 1,
  'tennis': 1,
  'valorant': 1,
  'yu-gi-oh': 1,
}

// "Mobile Legends: Bang Bang" becomes "mobile-legends-bang-bang".
export function gameSlug(name: string): string {
  return name
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

// The inline style that shows a game's banner, or undefined so the normal CSS art applies.
// The same seed (for example a tournament number) always picks the same variant.
export function gameBannerStyle(game: string | null | undefined, seed = 0): CSSProperties | undefined {
  if (!game) return undefined
  const slug = gameSlug(game)
  const count = BANNERS[slug]
  if (!count) return undefined
  const n = (Math.abs(Math.trunc(seed)) % count) + 1
  const file = n === 1 ? slug : `${slug}-${n}`
  return { backgroundImage: `url('/art/games/${file}.jpg')` }
}