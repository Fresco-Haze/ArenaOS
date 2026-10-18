import type { ReactNode } from 'react'

export default function PageHeader({
  title,
  meta,
  status,
  actions,
}: {
  title: string
  meta?: ReactNode
  status?: ReactNode
  actions?: ReactNode
}) {
  return (
    <header className="page-header">
      <div className="page-header-main">
        <div className="title-row">
          <h1>{title}</h1>
          {status}
        </div>
        {meta && <p className="meta">{meta}</p>}
      </div>
      {actions && <div className="page-header-actions">{actions}</div>}
    </header>
  )
}