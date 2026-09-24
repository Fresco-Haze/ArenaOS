import { Link, Route, Routes, useParams } from 'react-router'
import { useAuth } from './auth/context'
import HomePage from './pages/HomePage'
import LoginPage from './pages/LoginPage'
import TournamentPage from './pages/TournamentPage'
import RegisterPage from './pages/RegisterPage'
import ProtectedRoute from './components/ProtectedRoute'
import MyTournamentsPage from './pages/MyTournamentsPage'
import CreateTournamentPage from './pages/CreateTournamentPage'

function Header() {
  const { user, logout } = useAuth()
  return (
    <header className="site-header">
      <Link to="/" className="brand">ArenaOS</Link>
      <nav className="nav">
        {user ? (
          <>
            <span className="muted">{user.username}</span>
            <button onClick={logout}>Sign out</button>
          </>
        ) : (
          <Link to="/login">Sign in</Link>
        )}
      </nav>
    </header>
  )
}

function ExpiredNotice() {
  const { expired, dismissExpired } = useAuth()
  if (!expired) return null
  return (
    <p role="status" className="notice">
      <span>You were signed out.</span>
      <Link to="/login">Sign in again</Link>
      <button onClick={dismissExpired}>Dismiss</button>
    </p>
  )
}

function NotFound() {
  return (
    <>
      <h1>Page not found</h1>
      <p className="muted">There is nothing at this address.</p>
      <p>
        <Link to="/">Back to public tournaments</Link>
      </p>
    </>
  )
}

// The key makes React start a fresh page (and a fresh hook) for each tournament id.
function TournamentRoute() {
  const { id } = useParams()
  if (!id) return <NotFound />
  return <TournamentPage key={id} id={id} />
}

export default function App() {
  return (
    <div className="page">
      <Header />
      <ExpiredNotice />
      <main>
        <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/login" element={<LoginPage />} />
          <Route path="/register" element={<RegisterPage />} />
          <Route
            path="/me"
            element={
              <ProtectedRoute>
                <MyTournamentsPage />
              </ProtectedRoute>
            }
          />
          <Route
            path="/me/new"
            element={
              <ProtectedRoute>
                <CreateTournamentPage />
              </ProtectedRoute>
            }
          />
          <Route path="/tournaments/:id" element={<TournamentRoute />} />
          <Route path="*" element={<NotFound />} />
        </Routes>
      </main>
    </div>
  )
}