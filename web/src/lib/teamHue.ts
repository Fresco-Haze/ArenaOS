const HUES = [221, 199, 160, 38, 340, 265, 12, 180]

export function teamHue(name: string): number {
  let h = 0
  for (const c of name) h = (h * 31 + c.charCodeAt(0)) >>> 0
  return HUES[h % HUES.length]
}