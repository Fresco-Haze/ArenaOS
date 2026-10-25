import { Link } from 'react-router'
import PageHeader from '../components/PageHeader'

export default function HelpPage() {
  return (
    <>
      <PageHeader title="Help" />

      <section className="help-section">
        <h2>Joining a tournament</h2>
        <ol>
          <li>Sign in or create an account.</li>
          <li>Open a tournament that shows Registration open.</li>
          <li>
            Press Register Now. If the organizer approves each join, the button says Request to join
            instead, and you wait for approval.
          </li>
          <li>
            Watch the bell in the top bar. It tells you when your request is approved or declined, and
            when the tournament starts.
          </li>
        </ol>
        <p className="muted">
          You can withdraw, or cancel a pending request, while registration is open. A declined request
          cannot be repeated unless the organizer approves you.
        </p>
      </section>

      <section className="help-section">
        <h2>Running a tournament</h2>
        <ol>
          <li>Press Create Tournament, choose the format and who is competing, and save.</li>
          <li>Publish it, then open registration.</li>
          <li>
            Add players yourself (one name per line, or paste a list) and approve join requests if you
            asked for approval. Teams are registered by the organizer.
          </li>
          <li>Close registration, generate the bracket, then start the tournament.</li>
          <li>Record each result with Record score or Declare winner.</li>
          <li>Complete the tournament once the final, and the third-place match if you set one, are decided.</li>
        </ol>
        <p className="muted">
          Made a mistake? Finished matches can be corrected from the Completed matches section of the
          organizer controls.
        </p>
      </section>

      <section className="help-section">
        <h2>Formats</h2>
        <ul>
          <li>Single elimination: one loss and you are out. A third-place match is optional.</li>
          <li>Double elimination: your first loss sends you to the losers bracket, so everyone plays at least twice.</li>
          <li>Round robin: everyone plays everyone once. A win is 3 points and a draw is 1.</li>
        </ul>
      </section>

      <section className="help-section">
        <h2>Rankings and players</h2>
        <p>
          The <Link to="/rankings">Rankings</Link> and <Link to="/players">Players</Link> pages rank
          players by titles won, then match wins. Only public tournaments count. Player names are matched
          exactly, so Alice and alice are different players.
        </p>
      </section>
    </>
  )
}