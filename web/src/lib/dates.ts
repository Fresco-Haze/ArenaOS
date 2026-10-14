const pad = (n: number) => ('0' + n).slice(-2)

// dd/mm/yy, fixed format (does not depend on the browser locale).
export function formatDate(value: string | number | Date): string {
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return ''
  return `${pad(d.getDate())}/${pad(d.getMonth() + 1)}/${pad(d.getFullYear() % 100)}`
}

// dd/mm/yy, HH:mm (24-hour).
export function formatDateTime(value: string | number | Date): string {
  const d = new Date(value)
  if (Number.isNaN(d.getTime())) return ''
  return `${formatDate(d)}, ${pad(d.getHours())}:${pad(d.getMinutes())}`
}