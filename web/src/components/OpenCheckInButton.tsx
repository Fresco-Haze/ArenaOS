import { useState } from 'react'
import { ApiError } from '../api'
import { startCheckIn } from '../lib/tournamentActions'

const OPTIONS = [
  { value: '', label: 'No time limit' },
  { value: '10', label: '10 minutes' },
  { value: '15', label: '15 minutes' },
  { value: '30', label: '30 minutes' },
  { value: '60', label: '1 hour' },
  { value: '120', label: '2 hours' },
]

export default function OpenCheckInButton({ id, onDone }: { id: number; onDone: () => Promise<void> }) {
  const [mins, setMins] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  async function run() {
    setBusy(true)
    setError(null)
    try {
      await startCheckIn(id, mins === '' ? undefined : Number(mins))
      await onDone()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="ck-open">
      <label>
        Check-in closes after
        <select value={mins} onChange={(e) => setMins(e.target.value)}>
          {OPTIONS.map((o) => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
      </label>
      <button type="button" className="btn-primary" onClick={() => void run()} disabled={busy}>
        {busy ? 'Opening' : 'Open check-in'}
      </button>
      {error && <p role="alert" className="form-error">{error}</p>}
    </div>
  )
}