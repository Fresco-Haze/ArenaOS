// Which stream links get an embedded player. Only https links on exact, known hosts qualify;
// anything else is shown as a plain link. The server only checks that the link is https.

export type StreamInfo = {
  url: string
  label: string
  embedUrl: string | null
}

const TWITCH_HOSTS = ['twitch.tv', 'www.twitch.tv']
const YOUTUBE_HOSTS = ['youtube.com', 'www.youtube.com']

const TWITCH_CHANNEL = /^[A-Za-z0-9_]{1,25}$/
const YOUTUBE_ID = /^[A-Za-z0-9_-]{11}$/

// parentHost is window.location.hostname (Twitch refuses to embed without it).
export function parseStream(raw: string, parentHost: string): StreamInfo | null {
  let u: URL
  try {
    u = new URL(raw)
  } catch {
    return null
  }
  if (u.protocol !== 'https:') return null
  const host = u.hostname.toLowerCase()
  const parts = u.pathname.split('/').filter((s) => s !== '')
  const first = parts[0] ?? ''
  const second = parts[1] ?? ''
  const url = u.href

  if (TWITCH_HOSTS.includes(host)) {
    const ok = parts.length === 1 && TWITCH_CHANNEL.test(first) && parentHost !== ''
    const embedUrl = ok
      ? 'https://player.twitch.tv/?channel=' + first.toLowerCase() + '&parent=' + encodeURIComponent(parentHost)
      : null
    return { url, label: 'Twitch', embedUrl }
  }

  if (host === 'youtu.be') {
    const ok = parts.length === 1 && YOUTUBE_ID.test(first)
    return { url, label: 'YouTube', embedUrl: ok ? 'https://www.youtube.com/embed/' + first : null }
  }

  if (YOUTUBE_HOSTS.includes(host)) {
    let id = ''
    if (parts.length === 1 && first === 'watch') id = u.searchParams.get('v') ?? ''
    else if (parts.length === 2 && first === 'live') id = second
    const ok = YOUTUBE_ID.test(id)
    return { url, label: 'YouTube', embedUrl: ok ? 'https://www.youtube.com/embed/' + id : null }
  }

  // Kick is deliberately not embedded: its player showed "misconfigured" when tested.
  // Kick links fall through to the plain link below.
  return { url, label: 'stream', embedUrl: null }
}