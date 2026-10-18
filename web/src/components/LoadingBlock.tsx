export default function LoadingBlock({
  label = 'Loading',
  rows = 3,
}: {
  label?: string
  rows?: number
}) {
  return (
    <div role="status" aria-live="polite" className="loading-block">
      <span className="sr-only">{label}</span>
      {Array.from({ length: rows }, (_, i) => (
        <div key={i} className="skeleton" aria-hidden="true" />
      ))}
    </div>
  )
}