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