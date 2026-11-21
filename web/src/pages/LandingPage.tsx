import { Link } from 'react-router'
import { useApi } from '../hooks/useApi'
import { PublicStatsView, RankingList, TournamentList } from '../model'
import LoadingBlock from '../components/LoadingBlock'
import TournamentCard from '../components/TournamentCard'

const OPEN_STATES: readonly string[] = ['RegistrationOpen', 'InProgress']

const SAMPLE_MAPS: [string, string][] = [
  ['Mirage', '13-9'],
  ['Inferno', '11-13'],
  ['Nuke', '13-7'],
  ['Ancient', '8-6'],
  ['Anubis', '\u2014'],
]

function SampleMatch() {
  return (
    <aside className="lp-match" aria-label="Sample match">
      <div className="lp-match-top">
        <span>CS2 &middot; Winter Cup &middot; Upper Quarterfinal, Match 3</span>
        <span className="lp-sample">Sample</span>
      </div>
      <div className="lp-team">
        <span className="lp-seed">[1]</span>
        <span>Apex Vanguard</span>
        <span className="lp-score">2</span>
      </div>
      <div className="lp-team">
        <span className="lp-seed">[4]</span>
        <span>Nairobi Strikers</span>
        <span className="lp-score">1</span>
      </div>
      <p className="lp-match-meta">BO5 &middot; Map 4 &middot; 32:14</p>
      <ul className="lp-maps">
        {SAMPLE_MAPS.map(([m, s]) => (
          <li key={m}>
            <span>{m}</span>
            <span className="lp-score">{s}</span>
          </li>
        ))}
      </ul>
    </aside>
  )
}

type TopRow = { rank: number; player: string; titles: number; wins: number }

function SoonTag() {
  return <span className="soon-tag">Soon</span>
}

function Features({ top }: { top: TopRow[] | null }) {
  return (
    <section className="lp-section" aria-labelledby="lp-platform">
      <p className="lp-eyebrow">Platform</p>
      <h2 id="lp-platform" className="lp-h2">The infrastructure behind every bracket</h2>
      <div className="lp-grid">
        <article className="lp-card">
          <div className="lp-card-head">
            <h3>Automated Double-Elimination Brackets</h3>
            <span className="lp-sample">Sample</span>
          </div>
          <p className="muted">Seeds, byes, and lower-bracket drops are generated for you. Results advance teams automatically.</p>
          <div className="lp-mini" aria-hidden="true">
            <div className="lp-mini-col">
              <span className="lp-mini-box"><i>1</i>Apex Vanguard</span>
              <span className="lp-mini-box"><i>8</i>Frostbyte</span>
              <span className="lp-mini-box"><i>4</i>Nairobi Strikers</span>
              <span className="lp-mini-box"><i>5</i>Kilo Six</span>
            </div>
            <div className="lp-mini-col">
              <span className="lp-mini-box lp-mini-win">Apex Vanguard</span>
              <span className="lp-mini-box">Kilo Six</span>
            </div>
            <div className="lp-mini-col">
              <span className="lp-mini-label">Grand Final</span>
              <span className="lp-mini-box lp-mini-win">Apex Vanguard</span>
            </div>
          </div>
        </article>

        <article className="lp-card">
          <div className="lp-card-head">
            <h3>Instant Score &amp; Screenshot Verification</h3>
            <SoonTag />
          </div>
          <p className="muted">Both captains submit. Proof is matched, timestamped, and locked.</p>
          <div className="lp-file" aria-hidden="true">
            <span className="lp-file-tag">PNG</span>
            final_scoreboard_map3.png
          </div>
          <ul className="lp-checks" aria-hidden="true">
            <li>Captain A checked in</li>
            <li>Captain B checked in</li>
            <li>Scores match</li>
          </ul>
        </article>

        <article className="lp-card">
          <div className="lp-card-head">
            <h3>Rankings &amp; Leaderboards</h3>
          </div>
          <p className="muted">Built from real results: tournament titles and match wins.</p>
          {top === null || top.length === 0 ? (
            <p className="muted">Rankings appear once matches have been played.</p>
          ) : (
            <table className="rtable top-table">
              <thead>
                <tr>
                  <th className="num">#</th>
                  <th>Player</th>
                  <th className="num">Titles</th>
                  <th className="num">Wins</th>
                </tr>
              </thead>
              <tbody>
                {top.map((r) => (
                  <tr key={r.player}>
                    <td className="num">{r.rank}</td>
                    <td>{r.player}</td>
                    <td className="num">{r.titles}</td>
                    <td className="num">{r.wins}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </article>
      </div>
    </section>
  )
}

function Organizers() {
  return (
    <section className="lp-section" id="organizers" aria-labelledby="lp-org">
      <p className="lp-eyebrow">For Organizers</p>
      <h2 id="lp-org" className="lp-h2">Built for Tournament Organizers</h2>
      <p className="lp-lead">Run an event from one dashboard. No spreadsheets, no DM chaos.</p>
      <div className="lp-grid">
        <article className="lp-card">
          <p className="lp-label">Seeding</p>
          <h3>Auto-Seed Teams</h3>
          <p className="muted">Seeds and byes generated for you.</p>
        </article>
        <article className="lp-card">
          <p className="lp-label">Check-in</p>
          <h3>Check-In Control</h3>
          <p className="muted">Players check in during registration, and you see who showed up.</p>
        </article>
        <article className="lp-card">
          <p className="lp-label">Join requests</p>
          <h3>Approve Each Player</h3>
          <p className="muted">Approve or decline join requests, or add players yourself.</p>
        </article>
      </div>
    </section>
  )
}

function Closing() {
  return (
    <section className="lp-final" aria-labelledby="lp-final-h">
      <h2 id="lp-final-h" className="lp-h2">Ready to Enter the Lobby?</h2>
      <p className="lp-lead">Create your player profile and join your first bracket in minutes.</p>
      <Link to="/register" className="button-link btn-primary">Create Free Account</Link>
    </section>
  )
}

function LandingFooter() {
  return (
    <footer className="lp-foot">
      <div>
        <p className="lp-foot-brand">SweatLobby</p>
        <p className="muted">Competitive tournament infrastructure for players and organizers who take the game seriously.</p>
      </div>
      <nav aria-label="Platform">
        <h4>Platform</h4>
        <ul>
          <li><Link to="/tournaments">Tournaments</Link></li>
          <li><Link to="/rankings">Rankings</Link></li>
          <li><Link to="/games">Games</Link></li>
          <li><Link to="/players">Players</Link></li>
        </ul>
      </nav>
      <nav aria-label="Support">
        <h4>Support</h4>
        <ul>
          <li><Link to="/help">Help</Link></li>
        </ul>
      </nav>
      <nav aria-label="Legal">
        <h4>Legal</h4>
        <ul>
          <li><Link to="/terms">Terms of Service</Link></li>
          <li><Link to="/privacy">Privacy Policy</Link></li>
        </ul>
      </nav>
      <p className="lp-foot-legal muted">&copy; 2026 SweatLobby. All rights reserved.</p>
    </footer>
  )
}
export default function LandingPage() {
  const stats = useApi('/stats', PublicStatsView, true)
  const list = useApi('/tournaments', TournamentList, true)
  const rank = useApi('/rankings', RankingList, true)
  const top = rank.data ? rank.data.rankings.slice(0, 3) : null
  const games = stats.data ? stats.data.byGame : null
  const lobbies = list.data
    ? list.data.tournaments
        .filter((t) => OPEN_STATES.includes(t.state))
        .sort((a, b) => b.tournamentId - a.tournamentId)
        .slice(0, 3)
    : null
  const recent = list.data
    ? list.data.tournaments
        .filter((t) => t.state === 'Completed')
        .sort((a, b) => b.tournamentId - a.tournamentId)
        .slice(0, 2)
    : null

  return (
    <div className="lp">
      <section className="lp-hero" aria-labelledby="lp-title">
        <div className="lp-hero-copy">
          <p className="lp-eyebrow">Competitive lobbies &middot; Brackets &middot; Results</p>
          <h1 id="lp-title" className="lp-title">Competitive Lobbies Built for Serious Players</h1>
          <p className="lp-sub">
            Automated seeding, live results, and multi-game brackets that run themselves. Show up, play your set, and let the lobby handle the rest.
          </p>
          <div className="lp-cta">
            <Link to="/tournaments" className="button-link btn-primary">Browse Tournaments</Link>
            <Link to="/register?next=%2Fme%2Fnew" className="button-link">Host a Tournament</Link>
          </div>
        </div>
        <SampleMatch />
      </section>

      <section className="lp-section" aria-labelledby="lp-titles">
        <div className="lp-section-head">
          <h2 id="lp-titles">Supported Titles</h2>
          <Link to="/tournaments" className="panel-link">View All Tournaments &rarr;</Link>
        </div>
        {games && games.length > 0 && (
          <ul className="lp-games">
            {games.map(({ game, count }) => (
              <li key={game}>
                <Link to={'/tournaments?game=' + encodeURIComponent(game)} className="chip">
                  {game} <span className="muted">{count}</span>
                </Link>
              </li>
            ))}
          </ul>
        )}
        <h3 className="lp-sub-h">Active Lobbies</h3>
        {lobbies === null ? (
          <LoadingBlock label="Loading tournaments" />
        ) : lobbies.length === 0 ? (
          <p className="muted">No active lobbies right now.</p>
        ) : (
          <ul className="tcards tcards-featured">
            {lobbies.map((t) => (
              <TournamentCard key={t.tournamentId} tournament={t} />
            ))}
          </ul>
        )}
        {recent && recent.length > 0 && (
          <>
            <h3 className="lp-sub-h">Recent results</h3>
            <ul className="tcards tcards-featured">
              {recent.map((t) => (
                <TournamentCard key={t.tournamentId} tournament={t} />
              ))}
            </ul>
          </>
        )}
      </section>
      <Features top={top} />
      <Organizers />
      <Closing />
      <LandingFooter />
    </div>
  )
}