import GameFilter from '../components/GameFilter'
import { useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router'
import { api, ApiError } from '../api'
import { useApi } from '../hooks/useApi'
import { Game, TournamentList, gameLabel } from '../model'
import type { Tournament } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import PageHeader from '../components/PageHeader'
import TournamentCard from '../components/TournamentCard'
import DiscoveryHero from '../components/DiscoveryHero'

type Filters = { q: string; game: string; status: string; format: string; fee: string }
type Options = readonly (readonly [string, string])[]

const STATUS_OPTIONS = [['', 'Any status'], ['open', 'Open'], ['live', 'Live'], ['finished', 'Finished']] as const
const FORMAT_OPTIONS = [['', 'Any format'], ['single', 'Single elimination'], ['double', 'Double elimination'], ['roundrobin', 'Round robin']] as const
const FEE_OPTIONS = [['', 'Any entry'], ['free', 'Free'], ['paid', 'Paid']] as const

const SELECTS: { key: 'status' | 'format' | 'fee'; label: string; options: Options }[] = [
  { key: 'status', label: 'Status', options: STATUS_OPTIONS },
  { key: 'format', label: 'Format', options: FORMAT_OPTIONS },
  { key: 'fee', label: 'Entry', options: FEE_OPTIONS },
]

// Only accept values the backend knows; anything else in the URL is ignored.
function pick(value: string | null, options: Options): string {
  return value !== null && value !== '' && options.some(([v]) => v === value) ? value : ''
}

function labelOf(options: Options, value: string): string {
  return options.find(([v]) => v === value)?.[1] ?? ''
}

function query(f: Filters, offset = 0): string {
  const p = new URLSearchParams()
  if (f.q) p.set('q', f.q)
  if (f.game) p.set('game', f.game)
  if (f.status) p.set('status', f.status)
  if (f.format) p.set('format', f.format)
  if (f.fee) p.set('fee', f.fee)
  if (offset > 0) p.set('offset', String(offset))
  return p.toString()
}

export default function TournamentsPage() {
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const parsed = Game.safeParse(params.get('game'))
  const filters: Filters = {
    q: (params.get('q') ?? '').trim(),
    game: parsed.success ? parsed.data : '',
    status: pick(params.get('status'), STATUS_OPTIONS),
    format: pick(params.get('format'), FORMAT_OPTIONS),
    fee: pick(params.get('fee'), FEE_OPTIONS),
  }
  const qs = query(filters)
  const to = (f: Filters) => {
    const s = query(f)
    return s ? `/tournaments?${s}` : '/tournaments'
  }
  const href = (g: string) => to({ ...filters, game: g })

  return (
    <>
      <PageHeader title="Tournaments" />
      <div className="filter-panel filter-panel-row">
        <div className="filter-row">
          <GameFilter current={filters.game} href={href} />
          <div className="filter-selects">
            {SELECTS.map(({ key, label, options }) => (
              <select
                key={key}
                aria-label={label}
                value={filters[key]}
                onChange={(e) => navigate(to({ ...filters, [key]: e.target.value }))}
              >
                {options.map(([v, l]) => (
                  <option key={v} value={v}>{l}</option>
                ))}
              </select>
            ))}
          </div>
        </div>
      </div>
      {/* key = the filters, so changing them starts again from page one */}
      <Results key={qs} filters={filters} gameName={filters.game ? gameLabel[filters.game] : null} qs={qs} />
    </>
  )
}

function Results({ filters, gameName, qs }: { filters: Filters; gameName: string | null; qs: string }) {
  const list = useApi(qs ? `/tournaments?${qs}` : '/tournaments', TournamentList, true)
  const [more, setMore] = useState<Tournament[]>([])
  const [loadingMore, setLoadingMore] = useState(false)
  const [moreError, setMoreError] = useState<string | null>(null)

  const first = list.data ? list.data.tournaments : null
  const items = first ? [...first, ...more] : null
  const total = list.data?.total ?? null
  const filtered = Object.values(filters).some((v) => v !== '')
  const count = items ? (total ?? items.length) : 0
  const tags = [
    filters.status && labelOf(STATUS_OPTIONS, filters.status),
    filters.format && labelOf(FORMAT_OPTIONS, filters.format),
    filters.fee && labelOf(FEE_OPTIONS, filters.fee),
  ].filter(Boolean)

  async function loadMore() {
    if (!items) return
    setLoadingMore(true)
    setMoreError(null)
    try {
      const next = await api(`/tournaments?${query(filters, items.length)}`, TournamentList, { retryAnonymously: true })
      setMore((prev) => {
        const seen = new Set([...(first ?? []), ...prev].map((t) => t.tournamentId))
        return [...prev, ...next.tournaments.filter((t) => !seen.has(t.tournamentId))]
      })
    } catch (e) {
      setMoreError(e instanceof ApiError ? e.message : 'Could not reach the server')
    } finally {
      setLoadingMore(false)
    }
  }

  return (
    <>
      {!filtered && items && items.length > 0 && <DiscoveryHero items={items} />}
      {items && (
        <div className="results-bar">
          <p className="muted">
            <span className="num">{count}</span> {count === 1 ? 'tournament' : 'tournaments'}
            {filters.q && <> for &ldquo;{filters.q}&rdquo;</>}
            {gameName && <> in {gameName}</>}
            {tags.length > 0 && <> &middot; {tags.join(' \u00b7 ')}</>}
          </p>
          {filtered && <Link to="/tournaments" className="reset-link">Reset filters</Link>}
        </div>
      )}
      {list.error ? (
        <ErrorBanner message={list.error} onRetry={list.retry} />
      ) : items === null ? (
        <LoadingBlock label="Loading tournaments" />
      ) : items.length === 0 ? (
        filtered ? (
          <EmptyState
            title="No tournaments match"
            action={<Link to="/tournaments" className="button-link">Clear filters</Link>}
          >
            Try a different name, game or filter.
          </EmptyState>
        ) : (
          <EmptyState title="No public tournaments yet">
            Tournaments show up here once an organizer publishes one.
          </EmptyState>
        )
      ) : (
        <>
          <ul className="tcards">
            {items.map((t) => (
              <TournamentCard key={t.tournamentId} tournament={t} showOrganizer />
            ))}
          </ul>
          {total !== null && items.length < total && (
            <div className="load-more">
              <p className="muted">Showing {items.length} of {total}</p>
              <button type="button" onClick={() => void loadMore()} disabled={loadingMore}>
                {loadingMore ? 'Loading' : 'Load more'}
              </button>
              {moreError && <p role="alert" className="form-error">{moreError}</p>}
            </div>
          )}
        </>
      )}
    </>
  )
}