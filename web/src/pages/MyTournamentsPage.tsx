import { useState } from 'react'
import { Link } from 'react-router'
import { useApi } from '../hooks/useApi'
import { TournamentList } from '../model'

import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'
import Tabs from '../components/Tabs'
import TournamentRow from '../components/TournamentRow'

type TabId = 'created' | 'completed'

export default function MyTournamentsPage() {
  const list = useApi('/me/tournaments', TournamentList)
  const [tab, setTab] = useState<TabId>('created')

  const items = list.data ? list.data.tournaments : null
  const created = items ? items.filter((t) => t.state !== 'Completed') : []
  const completed = items ? items.filter((t) => t.state === 'Completed') : []
  const shown = tab === 'created' ? created : completed

  const createLink = (label: string) => (
    <Link to="/me/new" className="button-link btn-primary">
      {label}
    </Link>
  )

  return (
    <div className="mt">
      <PageHeader
        title="My tournaments"
        actions={items !== null && items.length === 0 ? undefined : createLink('Create tournament')}
      />
      <Tabs<TabId>
        label="My tournaments"
        active={tab}
        onChange={setTab}
        tabs={[
          { id: 'created', label: 'Created', ...(items ? { count: created.length } : {}) },
          { id: 'completed', label: 'Completed', ...(items ? { count: completed.length } : {}) },
        ]}
      />
      <div role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} className="mt-panel">
        {list.error ? (
          <ErrorBanner message={list.error} onRetry={list.retry} />
        ) : items === null ? (
          <LoadingBlock label="Loading tournaments" />
        ) : shown.length === 0 ? (
          tab === 'created' ? (
            <EmptyState title="No tournaments yet" action={createLink('Create your first tournament')}>
              Tournaments you create appear here.
            </EmptyState>
          ) : (
            <EmptyState title="Nothing completed yet">
              Finished tournaments show up here.
            </EmptyState>
          )
        ) : (
          <ul className="trows">
            {shown.map((t) => (
              <TournamentRow key={t.tournamentId} tournament={t} />
            ))}
          </ul>
        )}
      </div>
    </div>
  )
}