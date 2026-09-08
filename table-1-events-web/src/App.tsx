import { BrowserRouter, Navigate, Route, Routes, useNavigate, useParams } from "react-router-dom";
import { Home } from "./screens/Home";
import { Organizer } from "./screens/Organizer";
import { PlayerView } from "./screens/PlayerView";
import { PublicStandings } from "./screens/PublicStandings";

function HomeRoute() {
  const navigate = useNavigate();
  return <Home onOpenEvent={(id) => navigate(`/e/${id}`)} />;
}

function OrganizerRoute() {
  const { eventId } = useParams();
  const navigate = useNavigate();
  if (!eventId) return <Navigate to="/" replace />;
  return <Organizer eventId={eventId} onExit={() => navigate("/")} />;
}

function JoinRoute() {
  const { code } = useParams();
  return <PlayerView code={code} />;
}

function PlayerRoute() {
  const { eventId } = useParams();
  return <PlayerView eventIdProp={eventId} />;
}

function StandingsRoute() {
  const { eventId } = useParams();
  if (!eventId) return <Navigate to="/" replace />;
  return <PublicStandings eventId={eventId} />;
}

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<HomeRoute />} />
        <Route path="/e/:eventId" element={<OrganizerRoute />} />
        <Route path="/join/:code" element={<JoinRoute />} />
        <Route path="/p/:eventId" element={<PlayerRoute />} />
        <Route path="/s/:eventId" element={<StandingsRoute />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  );
}
