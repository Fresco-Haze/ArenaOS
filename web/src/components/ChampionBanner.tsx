export default function ChampionBanner({
  name,
  label = 'Champion',
}: {
  name: string
  label?: string
}) {
  return (
    <div className="champion-banner">
      <svg className="champion-icon" viewBox="0 0 24 24" width="32" height="32" aria-hidden="true">
        <path d="M7 4h10v5a5 5 0 0 1-10 0V4Z" />
        <path d="M7 6H4v2a3 3 0 0 0 3 3M17 6h3v2a3 3 0 0 1-3 3" />
        <path d="M12 14v4M8 20h8" />
      </svg>
      <div>
        <div className="champion-label">{label}</div>
        <div className="champion-name num">{name}</div>
      </div>
    </div>
  )
}