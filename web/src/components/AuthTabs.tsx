import { NavLink } from 'react-router'

export default function AuthTabs({ next }: { next: string }) {
  const q = '?next=' + encodeURIComponent(next)
  return (
    <nav className="auth-tabs" aria-label="Sign in or create an account">
      <NavLink to={'/login' + q} className="auth-tab">Sign In</NavLink>
      <NavLink to={'/register' + q} className="auth-tab">Create Account</NavLink>
    </nav>
  )
}