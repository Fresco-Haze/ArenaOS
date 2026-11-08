import PageHeader from '../components/PageHeader'

export default function PrivacyPage() {
  return (
    <>
      <PageHeader title="Privacy Policy" />
      <p className="muted">Last updated: 8 November 2026</p>

      <section className="help-section">
        <h2>Who we are</h2>
        <p>
          SweatLobby is run by Jae in Nairobi, Kenya. For anything in this policy, write to{' '}
          <a href="mailto:privacy@sweatlobby.com">privacy@sweatlobby.com</a>.
        </p>
      </section>

      <section className="help-section">
        <h2>What we collect</h2>
        <ul>
          <li>
            Account details: your username, your email address, and your password (not if you sign in only with Google). The password is
            stored only as a one-way scramble (a hash), so nobody, including us, can read it.
          </li>
          <li>Optional profile details: your full name, a short bio and a profile picture.</li>
          <li>
            If you use Continue with Google: the ID number Google gives your account, your Google email
            address and your Google name. We ask Google only for your basic profile and email address,
            never for your password, and we keep only those three things. We use them to sign you in and
            to create your account. Your Google name is saved as your full name, which can appear on
            public pages, and you can change it in Settings.
          </li>
          <li>
            Tournament activity: tournaments you create or join, teams, results, scores, rankings and
            your notifications.
          </li>
          <li>
            Security records: when an administrator changes an account&rsquo;s status or role, we keep
            a log of that action.
          </li>
          <li>
            Technical data: your IP address is held briefly in the server&rsquo;s memory to slow down
            repeated sign-in attempts, and our web server keeps ordinary request logs that rotate
            automatically.
          </li>
        </ul>
      </section>

      <section className="help-section">
        <h2>What other people can see</h2>
        <p>
          Your username, and the full name, bio and picture if you add them, can appear on public pages.
          Your tournament results and rankings are shown on public tournaments and ranking pages. Private
          tournaments are visible only to the people allowed to see them. Do not put anything in your bio
          or picture that you do not want to be public. Your password is never shown to anyone.
        </p>
      </section>

      <section className="help-section">
        <h2>How we use it</h2>
        <p>
          We use your data to run SweatLobby: signing you in, running tournaments, brackets and
          rankings, and sending you notifications inside the site. We also use it to keep the service
          secure and to stop abuse, and to contact you about your account if we need to. We do not sell
          your data, show advertising, or run analytics trackers.
        </p>
      </section>

      <section className="help-section">
        <h2>Cookies and browser storage</h2>
        <p>
          We do not use advertising or tracking cookies. If you use Continue with Google, we set one
          short-lived cookie (up to 10 minutes) that protects that sign-in from forgery, and your
          browser briefly notes the page you were on. Your browser also stores a sign-in token and a
          small copy of your basic
          profile so you stay signed in. Signing out removes the token.
        </p>
      </section>

      <section className="help-section">
        <h2>Who handles your data</h2>
        <ul>
          <li>Vultr hosts our servers, which are in Johannesburg, South Africa.</li>
          <li>
            Backblaze stores our encrypted backups. Its servers may be outside Kenya and South Africa.
          </li>
        </ul>
        <p>
          They handle data only to provide those services. We do not share your personal data with
          anyone else, unless the law requires us to.
          If you choose Continue with Google, Google is involved in that sign-in, and Google&rsquo;s own
          privacy policy covers your Google account.
        </p>
      </section>

      <section className="help-section">
        <h2>How long we keep it</h2>
        <p>
          We keep your data while your account exists. Backups are kept for 14 days on the server and about 30
          days in encrypted offsite storage. After an account is deleted, copies of it disappear from
          backups when those backups expire.
        </p>
      </section>

      <section className="help-section">
        <h2>Your choices and rights</h2>
        <p>
          You can change your name, bio, picture and password in Settings. You can also ask us for a
          copy of your data, ask us to correct it, or ask us to delete your account, by writing to{' '}
          <a href="mailto:privacy@sweatlobby.com">privacy@sweatlobby.com</a>. We will answer within 30
          days. When we delete an account we remove or anonymise your personal details, including the link to your Google account. Tournament
          results may remain, without your identity. You can also complain to Kenya&rsquo;s Office of
          the Data Protection Commissioner.
        </p>
      </section>

      <section className="help-section">
        <h2>Age</h2>
        <p>SweatLobby is for people aged 16 and over.</p>
      </section>

      <section className="help-section">
        <h2>Security</h2>
        <p>
          Connections to SweatLobby are encrypted, passwords are hashed, and repeated sign-in attempts
          are limited. No online service can promise perfect security. If you find a problem, please
          tell us at the address above.
        </p>
      </section>

      <section className="help-section">
        <h2>Changes</h2>
        <p>
          When we change this policy we update the date at the top, and for big changes we put a notice
          on the site.
        </p>
      </section>
    </>
  )
}
