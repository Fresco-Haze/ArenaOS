// "KSh 50,000" (whole shillings, fixed format).
export function formatKes(n: number): string {
  return `KSh ${n.toLocaleString('en-US')}`
}