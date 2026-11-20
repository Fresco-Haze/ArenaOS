// "2d 4h", "5h 12m", "45m". Returns null once the moment has passed.
export function countdownText(value: string, now: number): string | null {
  const at = new Date(value).getTime()
  if (Number.isNaN(at)) return null
  const mins = Math.floor((at - now) / 60000)
  if (mins < 1) return null
  const d = Math.floor(mins / 1440)
  const h = Math.floor((mins % 1440) / 60)
  const m = mins % 60
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${m}m`
  return `${m}m`
}