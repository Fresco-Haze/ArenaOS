import { Link, Route, Routes, useParams } from 'react-router'
import { useAuth } from './auth/context'
import HomePage from './pages/HomePage'
import TournamentsPage from './pages/TournamentsPage'
import RankingsPage from './pages/RankingsPage'
import GamesPage from './pages/GamesPage'
import ProfilePage from './pages/ProfilePage'
import LoginPage from './pages/LoginPage'
import TournamentPage from './pages/TournamentPage'
import RegisterPage from './pages/RegisterPage'
import ForgotPasswordPage from './pages/ForgotPasswordPage'
import ResetPasswordPage from './pages/ResetPasswordPage'
import ProtectedRoute from './components/ProtectedRoute'
import MyTournamentsPage from './pages/MyTournamentsPage'
import CreateTournamentPage from './pages/CreateTournamentPage'
import CreateTeamPage from './pages/CreateTeamPage'
import AppShell from './components/AppShell'

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
    <AppShell>
      <ExpiredNotice />
      <Routes>
          <Route path="/" element={<HomePage />} />
          <Route path="/tournaments" element={<TournamentsPage />} />
          <Route path="/rankings" element={<RankingsPage />} />
          <Route path="/games" element={<GamesPage />} />
          <Route
            path="/profile"
            element={
              <ProtectedRoute>
                <ProfilePage />
              </ProtectedRoute>
            }
          />
          <Route path="/login" element={<LoginPage />} />
          <Route path="/register" element={<RegisterPage />} />
          <Route path="/forgot-password" element={<ForgotPasswordPage />} />
          <Route path="/reset-password" element={<ResetPasswordPage />} />
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
          <Route
            path="/teams/new"
            element={
              <ProtectedRoute>
                <CreateTeamPage />
              </ProtectedRoute>
           }
         />
      </Routes>
    </AppShell>
  )
}