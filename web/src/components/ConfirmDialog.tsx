import { useEffect, useRef, useState } from 'react'
import { ApiError } from '../api'
import type { ReactNode, SyntheticEvent } from 'react'

type Props = {
  open: boolean
  title: string
  confirmLabel: string
  onConfirm: () => Promise<void>
  onClose: () => void
  children?: ReactNode
}

export default function ConfirmDialog({ open, title, confirmLabel, onConfirm, onClose, children }: Props) {
  const ref = useRef<HTMLDialogElement>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    if (open && !el.open) el.showModal()
    if (!open && el.open) el.close()
  }, [open])

  async function handleConfirm() {
    setBusy(true)
    setError(null)
    try {
      await onConfirm()
      onClose()
    } catch (e) {
      setError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setBusy(false)
    }
  }

  function handleCancel(e: React.SyntheticEvent<HTMLDialogElement>) {
    // Don't let Escape close the dialog mid-request — same protection the Cancel button gets.
    if (busy) {
      e.preventDefault()
      return
    }
    onClose()
  }

  return (
    <dialog ref={ref} className="dialog" aria-labelledby="confirm-dialog-title" onCancel={handleCancel}>
      <h2 id="confirm-dialog-title">{title}</h2>
      {children}
      {error && <p role="alert" className="form-error">{error}</p>}
      <div className="dialog-actions">
        <button onClick={onClose} disabled={busy}>Cancel</button>
        <button onClick={handleConfirm} disabled={busy}>
          {busy ? 'Working' : confirmLabel}
        </button>
      </div>
    </dialog>
  )
}