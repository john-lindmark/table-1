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
import { Profile } from "./screens/Profile";
import { QrJoin } from "./screens/QrJoin";
import { AddPlayers } from "./screens/AddPlayers";
import { LifeTracker } from "./screens/LifeTracker";
import { AddCards, AllCards, CardDetail, LibraryHome } from "./screens/Library";

/** Back where the user came from, or a sensible default when the tracker was opened directly. */
function useBack(fallback: string) {
  const navigate = useNavigate();
  return () => {
    const idx = (window.history.state as { idx?: number } | null)?.idx ?? 0;
    if (idx > 0) navigate(-1);
    else navigate(fallback, { replace: true });
  };
}

function HomeRoute() {
  const navigate = useNavigate();
  return (
    <Home
      onOpenEvent={(id) => navigate(`/e/${id}`)}
      onOpenPlayer={(id) => navigate(`/p/${id}`)}
      onAddPlayers={(id) => {
        // Straight to inviting people; Back lands on the new event.
        navigate(`/e/${id}`);
        navigate(`/e/${id}/add`);
      }}
      onOpenLife={(matchId) => navigate(matchId ? `/life/${matchId}` : "/life")}
    />
  );
}

function OrganizerRoute() {
  const { eventId } = useParams();
  const navigate = useNavigate();
  if (!eventId) return <Navigate to="/" replace />;
  return (
    <Organizer
      eventId={eventId}
      onExit={() => navigate("/")}
      onAddPlayers={() => navigate(`/e/${eventId}/add`)}
      onOpenLife={(matchId) => navigate(`/life/${matchId}`)}
    />
  );
}

function AddPlayersRoute() {
  const { eventId } = useParams();
  const navigate = useNavigate();
  if (!eventId) return <Navigate to="/" replace />;
  return <AddPlayers eventId={eventId} onDone={() => navigate(`/e/${eventId}`)} />;
}

function JoinRoute() {
  const { code } = useParams();
  const navigate = useNavigate();
  return <PlayerView code={code} onOpenLife={(matchId) => navigate(`/life/${matchId}`)} />;
}

function QrJoinRoute() {
  const { code } = useParams();
  const navigate = useNavigate();
  const secret = new URLSearchParams(useLocation().search).get("s");
  if (!code) return <Navigate to="/" replace />;
  return <QrJoin code={code} secret={secret} onJoined={(id) => navigate(`/p/${id}`, { replace: true })} />;
}

function ProfileRoute() {
  const navigate = useNavigate();
  return <Profile onSignedOut={() => navigate("/")} />;
}

function PlayerRoute() {
  const { eventId } = useParams();
  const navigate = useNavigate();
  return <PlayerView eventIdProp={eventId} onOpenLife={(matchId) => navigate(`/life/${matchId}`)} />;
}

/** /life is the local tracker (no event); /life/:matchId is the shared tracker for a match. */
function LifeRoute() {
  const { matchId } = useParams();
  const back = useBack("/");
  return <LifeTracker key={matchId ?? "local"} matchId={matchId} onClose={back} />;
}

function LibraryHomeRoute() {
  const navigate = useNavigate();
  return <LibraryHome onAllCards={() => navigate("/library/cards")} onAdd={() => navigate("/library/add")} />;
}

function AllCardsRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return (
    <AllCards onBack={back} onOpen={(id) => navigate(`/library/card/${id}`)} onAdd={() => navigate("/library/add")} />
  );
}

function AddCardsRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <AddCards onBack={back} onOpen={(id) => navigate(`/library/card/${id}`)} />;
}

function CardDetailRoute() {
  const { oracleId } = useParams();
  const back = useBack("/library/cards");
  if (!oracleId) return <Navigate to="/library" replace />;
  return <CardDetail key={oracleId} oracleId={oracleId} onBack={back} />;
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
        <Route path="/e/:eventId/add" element={<AddPlayersRoute />} />
        <Route path="/join/:code" element={<JoinRoute />} />
        <Route path="/j/:code" element={<QrJoinRoute />} />
        <Route path="/me" element={<ProfileRoute />} />
        <Route path="/p/:eventId" element={<PlayerRoute />} />
        <Route path="/s/:eventId" element={<StandingsRoute />} />
        <Route path="/library" element={<LibraryHomeRoute />} />
        <Route path="/library/cards" element={<AllCardsRoute />} />
        <Route path="/library/add" element={<AddCardsRoute />} />
        <Route path="/library/card/:oracleId" element={<CardDetailRoute />} />
        <Route path="/life" element={<LifeRoute />} />
        <Route path="/life/:matchId" element={<LifeRoute />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  );
}
