import { useNavigate } from 'react-router'
import CreateTeamForm from '../components/CreateTeamForm'

export default function CreateTeamPage() {
  const navigate = useNavigate()
  return (
    <div className="tm-create">
      <h1>Create a team</h1>
      <CreateTeamForm onDone={() => navigate(-1)} onCancel={() => navigate(-1)} />
    </div>
  )
}