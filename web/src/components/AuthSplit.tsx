import type { ReactNode } from 'react'
import AuthBrand from './AuthBrand'

export default function AuthSplit({ children }: { children: ReactNode }) {
  return (
    <div className="auth-split">
      <aside className="auth-panel" aria-label="About SweatLobby">
        <AuthBrand />
        <p className="auth-panel-title">
          Real players. Real tournaments. <span>Your stage.</span>
        </p>
        <p className="auth-panel-text">
          Compete in exciting tournaments, build your team, climb the ranks and be part of a growing gaming community.
        </p>
        <ul className="auth-points">
          <li>Brackets and lobbies, run end to end</li>
          <li>Check-in, match results and winner predictions</li>
          <li>Teams for squad tournaments</li>
        </ul>
      </aside>
      <div className="auth-main">{children}</div>
    </div>
  )
}