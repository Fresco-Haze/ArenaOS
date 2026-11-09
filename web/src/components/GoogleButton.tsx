import { useGoogleEnabled } from '../hooks/useGoogleEnabled'
import { startGoogle } from '../lib/googleSignIn'

// Shows nothing unless the server has Google sign-in switched on.
export default function GoogleButton({ next }: { next: string }) {
  const enabled = useGoogleEnabled()
  if (!enabled) return null
  return (
    <div className="google-signin">
      <p className="google-or" aria-hidden="true">or</p>
      <button type="button" className="google-btn" onClick={() => startGoogle(next)}>
        Continue with Google
      </button>
    </div>
  )
}