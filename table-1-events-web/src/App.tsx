import { useEffect } from "react";
import {
  BrowserRouter,
  Navigate,
  Route,
  Routes,
  useLocation,
  useNavigate,
  useParams,
} from "react-router-dom";
import { trackPageView } from "./lib/analytics";
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

/** Sends one redacted page view per navigation, including the first. */
function RouteAnalytics() {
  const location = useLocation();
  useEffect(() => {
    trackPageView(location.pathname, location.search);
  }, [location.pathname, location.search]);
  return null;
}

export default function App() {
  return (
    <BrowserRouter>
      <RouteAnalytics />
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
