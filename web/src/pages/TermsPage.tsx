import PageHeader from '../components/PageHeader'

export default function TermsPage() {
  return (
    <>
      <PageHeader title="Terms of Use" />
      <p className="muted">Last updated: 8 November 2026</p>

      <section className="help-section">
        <h2>Using SweatLobby</h2>
        <p>
          SweatLobby is a place to run and follow competitive gaming tournaments. By creating an
          account or using the site, you agree to these terms. If you do not agree, please do not use
          it. You must be at least 16 years old.
        </p>
      </section>

      <section className="help-section">
        <h2>Your account</h2>
        <ul>
          <li>Give accurate details and keep your password secret.</li>
          <li>You are responsible for what happens under your account.</li>
          <li>Use one account per person.</li>
          <li>Tell us straight away if you think someone else has got into your account.</li>
          <li>If you sign in with Google, keep your Google account secure too. Google&rsquo;s own terms apply to it.</li>
        </ul>
      </section>

      <section className="help-section">
        <h2>How to behave</h2>
        <ul>
          <li>Do not cheat, or manipulate results, brackets or rankings.</li>
          <li>Do not harass, threaten or abuse other people, or post hateful content.</li>
          <li>Do not pretend to be someone else.</li>
          <li>Do not post illegal or sexual content, including in your bio or profile picture.</li>
          <li>
            Do not attack or overload the service, try to get into other people&rsquo;s accounts, or
            create accounts automatically.
          </li>
        </ul>
      </section>

      <section className="help-section">
        <h2>Tournaments and organizers</h2>
        <p>
          Organizers run their own tournaments and set their own rules. SweatLobby does not collect
          entry fees or hold prizes, and it is not part of any arrangement about money or prizes
          between organizers and players. Any entry fee or prize is between you and the organizer, so
          check the details before you join.
        </p>
      </section>

      <section className="help-section">
        <h2>Your content</h2>
        <p>
          You keep ownership of what you post, such as your bio and profile picture. You allow us to
          store it and show it on the site so the service can work. You promise you have the right to
          post it.
        </p>
      </section>

      <section className="help-section">
        <h2>Suspension and removal</h2>
        <p>
          We may remove content, cancel tournaments, or suspend or close accounts that break these
          terms or put other people or the service at risk. You can stop using SweatLobby at any time
          and ask us to delete your account.
        </p>
      </section>

      <section className="help-section">
        <h2>The service as it is</h2>
        <p>
          SweatLobby is new and run by one person. We do our best and we back up the data, but the
          service may change, be unavailable, or lose data, and we cannot promise otherwise. It is
          provided &ldquo;as is&rdquo;. As far as the law allows, we are not responsible for indirect
          losses, or for losses linked to entry fees, prizes or disputes between users. Nothing here
          limits any right you have under Kenyan law that cannot be limited.
        </p>
      </section>

      <section className="help-section">
        <h2>Changes and law</h2>
        <p>
          We may update these terms. The date at the top shows the latest version, and if you keep
          using SweatLobby after a change, you accept it. These terms are governed by the laws of
          Kenya.
        </p>
      </section>

      <section className="help-section">
        <h2>Contact</h2>
        <p>
          Write to <a href="mailto:privacy@sweatlobby.com">privacy@sweatlobby.com</a>.
        </p>
      </section>
    </>
  )
}
