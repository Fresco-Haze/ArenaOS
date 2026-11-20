import { useState } from 'react'
import { teamHue } from '../lib/teamHue'

// Shows the team's uploaded logo when `team` is set and one exists; otherwise a crest
// generated from the name. `version` busts the cache after an upload or removal.
export default function TeamCrest({
  name,
  size = 48,
  team = false,
  version = 0,
}: {
  name: string
  size?: number
  team?: boolean
  version?: number
}) {
  const key = `${name}:${version}`
  const [failed, setFailed] = useState<string | null>(null)

  if (team && name !== '' && failed !== key) {
    return (
      <img
        className="crest crest-img"
        src={`/api/teams/${encodeURIComponent(name)}/logo?v=${version}`}
        width={size}
        height={size}
        alt={`${name} logo`}
        onError={() => setFailed(key)}
      />
    )
  }

  const hue = teamHue(name)
  const initials = name.replace(/[^a-zA-Z0-9]/g, '').slice(0, 2).toUpperCase() || '?'
  return (
    <span
      className="crest"
      role="img"
      aria-label={`${name} crest`}
      style={{
        width: size,
        height: size,
        fontSize: Math.round(size * 0.36),
        background: `linear-gradient(135deg, hsl(${hue} 70% 22%), hsl(${hue} 75% 48%))`,
      }}
    >
      {initials}
    </span>
  )
}