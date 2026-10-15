import { useEffect } from "react";
import {
  BrowserRouter,
  Navigate,
  Route,
  Routes,
  useLocation,
  useNavigate,
  useParams,
  useSearchParams,
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
import { LinePrintingScreen, ListAddScreen, ListScreen, ListsScreen, VersionScreen, VersionsScreen } from "./screens/Lists";
import type { Board, ListFinish } from "./lib/lists";
import { DeckFinderScreen } from "./screens/DeckFinder";

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
  return (
    <LibraryHome onAllCards={() => navigate("/library/cards")} onAdd={() => navigate("/library/add")}
                 onDecks={() => navigate("/library/decks")} onCubes={() => navigate("/library/cubes")} />
  );
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

function ListsRoute({ kind }: { kind: "deck" | "cube" }) {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <ListsScreen key={kind} kind={kind} onBack={back} onOpen={(id) => navigate(`/library/list/${id}`)}
                      onFind={() => navigate("/library/find")} />;
}

function ListRoute() {
  const { listId } = useParams();
  const navigate = useNavigate();
  const back = useBack("/library/decks");
  if (!listId) return <Navigate to="/library" replace />;
  return (
    <ListScreen id={listId} onBack={back} onCard={(o) => navigate(`/library/card/${o}`)}
                onAdd={() => navigate(`/library/list/${listId}/add`)} onVersions={() => navigate(`/library/list/${listId}/versions`)}
                onOpen={(id) => navigate(`/library/list/${id}`)}
                onPrinting={(card, board, finish) => navigate(`/library/list/${listId}/printing?card=${card}&board=${board}&finish=${finish}`)} />
  );
}

function LinePrintingRoute() {
  const { listId } = useParams();
  const [q] = useSearchParams();
  const back = useBack(`/library/list/${listId}`);
  if (!listId) return <Navigate to="/library" replace />;
  return <LinePrintingScreen id={listId} cardId={q.get("card") ?? ""} board={(q.get("board") ?? "main") as Board}
                             finish={(q.get("finish") ?? "nonfoil") as ListFinish} onDone={back} />;
}

function DeckFinderRoute() {
  const navigate = useNavigate();
  const back = useBack("/library/decks");
  return <DeckFinderScreen onBack={back} onCreated={(id) => navigate(`/library/list/${id}`, { replace: true })} />;
}

function ListAddRoute() {
  const { listId } = useParams();
  const navigate = useNavigate();
  const back = useBack(`/library/list/${listId}`);
  if (!listId) return <Navigate to="/library" replace />;
  return <ListAddScreen id={listId} onDone={back} onCard={(o) => navigate(`/library/card/${o}`)} />;
}

function VersionsRoute() {
  const { listId } = useParams();
  const navigate = useNavigate();
  const back = useBack(`/library/list/${listId}`);
  if (!listId) return <Navigate to="/library" replace />;
  return <VersionsScreen id={listId} onBack={back} onOpen={(n) => navigate(`/library/list/${listId}/v/${n}`)} />;
}

function VersionRoute() {
  const { listId, n } = useParams();
  const navigate = useNavigate();
  const back = useBack(`/library/list/${listId}/versions`);
  if (!listId || !n) return <Navigate to="/library" replace />;
  return <VersionScreen id={listId} number={Number(n)} onBack={back} onCard={(o) => navigate(`/library/card/${o}`)} />;
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
        <Route path="/library/decks" element={<ListsRoute kind="deck" />} />
        <Route path="/library/find" element={<DeckFinderRoute />} />
        <Route path="/library/list/:listId/printing" element={<LinePrintingRoute />} />
        <Route path="/library/cubes" element={<ListsRoute kind="cube" />} />
        <Route path="/library/list/:listId" element={<ListRoute />} />
        <Route path="/library/list/:listId/add" element={<ListAddRoute />} />
        <Route path="/library/list/:listId/versions" element={<VersionsRoute />} />
        <Route path="/library/list/:listId/v/:n" element={<VersionRoute />} />
        <Route path="/life" element={<LifeRoute />} />
        <Route path="/life/:matchId" element={<LifeRoute />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </BrowserRouter>
  );
}
