import { useState } from 'react'
import { useAuth } from '../auth/context'

// The signed-in user's picture, or their initial when there is none.
export default function Avatar({ className = 'avatar' }: { className?: string }) {
  const { user, avatarVersion } = useAuth()
  const [failedKey, setFailedKey] = useState<string | null>(null)
  if (!user) return null
  const key = `${user.id}:${avatarVersion}`
  if (user.hasAvatar && failedKey !== key) {
    return (
      <img
        className={className}
        src={`/api/avatars/${user.id}?v=${avatarVersion}`}
        alt=""
        onError={() => setFailedKey(key)}
      />
    )
  }
  return <span className={className} aria-hidden="true">{user.username.charAt(0).toUpperCase()}</span>
}