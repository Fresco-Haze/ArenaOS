export type Stat = { label: string; value: string; sub?: string; text?: boolean }

export default function StatStrip({ stats }: { stats: Stat[] }) {
  return (
    <div className="stat-strip">
      {stats.map((s) => (
        <div key={s.label} className="stat">
          <div className={'stat-value num' + (s.text ? ' stat-value-text' : '')}>
            {s.value}
            {s.sub && <span className="stat-sub"> {s.sub}</span>}
          </div>
          <div className="stat-label">{s.label}</div>
        </div>
      ))}
    </div>
  )
}