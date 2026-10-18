export default function ErrorBanner({
  message,
  onRetry,
}: {
  message: string
  onRetry?: () => void
}) {
  return (
    <div role="alert" className="error-banner">
      <span>{message}</span>
      {onRetry && <button onClick={onRetry}>Try again</button>}
    </div>
  )
}