import { useEffect, useState } from 'react'
import { Link } from 'react-router'
import { api, ApiError } from '../api'
import { TournamentList } from '../model'
import type { Tournament } from '../model'
import EmptyState from '../components/EmptyState'
import ErrorBanner from '../components/ErrorBanner'
import LoadingBlock from '../components/LoadingBlock'
import TournamentCard from '../components/TournamentCard'

// The backend has no "featured" concept: the four newest public
// tournaments that are open for registration or running.
const FEATURED_STATES: readonly string[] = ['RegistrationOpen', 'InProgress']

function TrophyIcon() {
  return (
    <svg className="panel-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M8 4h8v5a4 4 0 0 1-8 0V4zM8 6H4v2a3 3 0 0 0 3 3M16 6h4v2a3 3 0 0 1-3 3M12 13v4M8 20h8M10 17h4" />
    </svg>
  )
}

function Hero() {
  return (
    <section className="hero" aria-labelledby="hero-title">
      <div className="hero-copy">
        <p className="hero-eyebrow">Welcome to ArenaOS</p>
        <h1 id="hero-title" className="hero-title">
          <span>Real players.</span>
          <span className="hero-accent">Real tournaments.</span>
          <span className="hero-accent">Your stage.</span>
        </h1>
        <p className="hero-text">
          Compete in exciting tournaments, build your team, climb the ranks and be part of a growing gaming community.
        </p>
        <Link to="/tournaments" className="button-link btn-primary">Explore Tournaments &rarr;</Link>
      </div>
    </section>
  )
}

export default function HomePage() {
  const [items, setItems] = useState<Tournament[] | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    let cancelled = false
    api('/tournaments', TournamentList, { retryAnonymously: true })
      .then((d) => {
        if (!cancelled) setItems(d.tournaments)
      })
      .catch((e: unknown) => {
        if (!cancelled) {
          setError(e instanceof ApiError ? e.message : 'Could not reach the server')
        }
      })
    return () => {
      cancelled = true
    }
  }, [attempt])

  function retry() {
    setError(null)
    setItems(null)
    setAttempt((n) => n + 1)
  }

  const featured =
    items === null
      ? null
      : items
          .filter((t) => FEATURED_STATES.includes(t.state))
          .sort((a, b) => b.tournamentId - a.tournamentId)
          .slice(0, 4)

  return (
    <>
      <Hero />
      <section className="panel" aria-labelledby="featured-heading">
        <div className="panel-head">
          <h2 id="featured-heading" className="panel-title">
            <TrophyIcon />
            Featured Tournaments
          </h2>
          <Link to="/tournaments" className="panel-link">View All &rarr;</Link>
        </div>
        {error ? (
          <ErrorBanner message={error} onRetry={retry} />
        ) : featured === null ? (
          <LoadingBlock label="Loading tournaments" />
        ) : featured.length === 0 ? (
          <EmptyState
            title="Nothing open right now"
            action={<Link to="/tournaments" className="button-link">Browse all tournaments</Link>}
          >
            Tournaments that are open for registration or running show up here.
          </EmptyState>
        ) : (
          <ul className="tcards">
            {featured.map((t) => (
              <TournamentCard key={t.tournamentId} tournament={t} />
            ))}
          </ul>
        )}
      </section>
    </>
  )
}