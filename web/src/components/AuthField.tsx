import { useId, useState } from 'react'
import type { InputHTMLAttributes } from 'react'

const PATHS = {
  user: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM4 21c0-4 4-6 8-6s8 2 8 6',
  mail: 'M3 6h18v12H3zM3 7l9 6 9-6',
  lock: 'M6 11h12v9H6zM8 11V8a4 4 0 0 1 8 0v3',
} as const

const EYE = 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z'

type Props = Omit<InputHTMLAttributes<HTMLInputElement>, 'className' | 'id'> & {
  label: string
  icon: keyof typeof PATHS
  hideLabel?: boolean
  password?: boolean
  error?: string
}

export default function AuthField({ label, icon, hideLabel, password, error, ...input }: Props) {
  const id = useId()
  const [shown, setShown] = useState(false)
  return (
    <div className="afield">
      <label htmlFor={id} className={hideLabel ? 'sr-only' : undefined}>{label}</label>
      <div className="afield-box">
        <svg className="afield-icon" viewBox="0 0 24 24" aria-hidden="true">
          <path d={PATHS[icon]} />
        </svg>
        <input id={id} {...input} type={password ? (shown ? 'text' : 'password') : (input.type ?? 'text')} />
        {password && (
          <button
            type="button"
            className="afield-eye"
            aria-label={shown ? 'Hide password' : 'Show password'}
            aria-pressed={shown}
            onClick={() => setShown((s) => !s)}
          >
            <svg className="afield-icon-eye" viewBox="0 0 24 24" aria-hidden="true">
              <path d={EYE} />
              {shown && <path d="M4 4l16 16" />}
            </svg>
          </button>
        )}
      </div>
      {error && <span role="alert" className="form-error">{error}</span>}
    </div>
  )
}