const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']

// "Nov 8, 2026 \u2022 7:00 PM", fixed format, shown in the browser's local time.
export function formatCardDate(value: string): string {
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return ''
  const h = d.getHours()
  const h12 = h % 12 === 0 ? 12 : h % 12
  const mm = ('0' + d.getMinutes()).slice(-2)
  return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()} \u2022 ${h12}:${mm} ${h < 12 ? 'AM' : 'PM'}`
}

// "Starts in 45m", "Starts in 12h", "Starts in 2d": relative to `now` (ms), rounded down.
export function startsIn(value: string, now: number): string {
  const at = new Date(value).getTime()
  if (Number.isNaN(at)) return ''
  const mins = Math.floor((at - now) / 60000)
  if (mins < 1) return 'Starting now'
  if (mins < 60) return `Starts in ${mins}m`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `Starts in ${hours}h`
  return `Starts in ${Math.floor(hours / 24)}d`
}

// "just now", "5m ago", "3h ago", "2d ago": relative to `now` (ms), rounded down.
export function timeAgo(value: string, now: number): string {
  const at = new Date(value).getTime()
  if (Number.isNaN(at)) return ''
  const mins = Math.floor((now - at) / 60000)
  if (mins < 1) return 'just now'
  if (mins < 60) return `${mins}m ago`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}
