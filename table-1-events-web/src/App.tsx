import { Suspense, lazy, useEffect, useRef, type ComponentType } from "react";
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
import { screenName } from "./lib/analytics";
import { listKindOf } from "./lib/lists";
import { pageView } from "./lib/telemetry";
import { Home } from "./screens/Home";
import { Organizer } from "./screens/Organizer";
import { PlayerView } from "./screens/PlayerView";
import { PublicStandings } from "./screens/PublicStandings";
import { Profile } from "./screens/Profile";
import { QrJoin } from "./screens/QrJoin";
import { AddPlayers } from "./screens/AddPlayers";
import { LifeTracker } from "./screens/LifeTracker";
import { AuthConfirm } from "./screens/AuthConfirm";
import { DeleteAccountPage, PrivacyPolicy } from "./screens/Legal";
import { SignInPage } from "./screens/Landing";
import { NameGate } from "./components/NameGate";
import type { Board, ListFinish } from "./lib/lists";

/**
 * The Library (catalog, collection, decks and cubes) loads on first visit, so players who only use events never
 * download it. One import per module; Vite splits each into its own chunk.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function lazyNamed<M, K extends keyof M>(load: () => Promise<M>, name: K): M[K] {
  return lazy(() => load().then((m) => ({ default: m[name] as unknown as ComponentType<any> }))) as unknown as M[K];
}
const library = () => import("./screens/Library");
const lists = () => import("./screens/Lists");
const LibraryHome = lazyNamed(library, "LibraryHome");
const AllCards = lazyNamed(library, "AllCards");
const AddCards = lazyNamed(library, "AddCards");
const CardDetail = lazyNamed(library, "CardDetail");
const ListsScreen = lazyNamed(lists, "ListsScreen");
const ListScreen = lazyNamed(lists, "ListScreen");
const ListAddScreen = lazyNamed(lists, "ListAddScreen");
const VersionsScreen = lazyNamed(lists, "VersionsScreen");
const VersionScreen = lazyNamed(lists, "VersionScreen");
const LinePrintingScreen = lazyNamed(lists, "LinePrintingScreen");
const listStats = () => import("./screens/ListStats");
const ListStatsScreen = lazyNamed(listStats, "ListStatsScreen");
const SampleHandScreen = lazyNamed(listStats, "SampleHandScreen");
const DrawOddsScreen = lazyNamed(listStats, "DrawOddsScreen");
const SamplePackScreen = lazyNamed(listStats, "SamplePackScreen");
const trades = () => import("./screens/Trades");
const TradesScreen = lazyNamed(trades, "TradesScreen");
const TradeScreen = lazyNamed(trades, "TradeScreen");
const binders = () => import("./screens/Binders");
const BindersScreen = lazyNamed(binders, "BindersScreen");
const BinderScreen = lazyNamed(binders, "BinderScreen");
const WantsScreen = lazyNamed(binders, "WantsScreen");
const DeckFinderScreen = lazyNamed(() => import("./screens/DeckFinder"), "DeckFinderScreen");
const ListImportScreen = lazyNamed(() => import("./screens/ListImport"), "ListImportScreen");
const CollectionImportScreen = lazyNamed(() => import("./screens/CollectionImport"), "CollectionImportScreen");
const EventsDemo = lazyNamed(() => import("./screens/EventsDemo"), "EventsDemo");
// Dev only: production builds drop the demo and its fixture.
const RotoDemo = import.meta.env.DEV ? lazyNamed(() => import("./screens/RotoDemo"), "RotoDemo") : () => null;

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
                 onDecks={() => navigate("/library/decks")} onCubes={() => navigate("/library/cubes")}
                 onTrades={() => navigate("/library/trades")} onImport={() => navigate("/library/import")}
                 onBinders={() => navigate("/library/binders")} onWants={() => navigate("/library/wants")} />
  );
}

function BindersRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <BindersScreen onBack={back} onOpen={(id) => navigate(`/library/binder/${id}`)} />;
}

function BinderRoute() {
  const { binderId } = useParams();
  const navigate = useNavigate();
  const back = useBack("/library/binders");
  if (!binderId) return <Navigate to="/library/binders" replace />;
  return <BinderScreen key={binderId} id={binderId} onBack={back} onCard={(o) => navigate(`/library/card/${o}`)} />;
}

function WantsRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <WantsScreen onBack={back} onCard={(o) => navigate(`/library/card/${o}`)} />;
}

function CollectionImportRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <CollectionImportScreen onBack={back} onAllCards={() => navigate("/library/cards")} />;
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
                      onFind={() => navigate("/library/find")} onImport={() => navigate(`/library/import/${kind}`)} />;
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
                onPrinting={(card, board, finish) => navigate(`/library/list/${listId}/printing?card=${card}&board=${board}&finish=${finish}`)}
                onStats={() => navigate(`/library/list/${listId}/stats`)} />
  );
}

function ListStatsRoute() {
  const { listId } = useParams();
  const navigate = useNavigate();
  const back = useBack(`/library/list/${listId}`);
  if (!listId) return <Navigate to="/library" replace />;
  const to = (page: string) => () => navigate(`/library/list/${listId}/stats/${page}`);
  return <ListStatsScreen id={listId} onBack={back} onHand={to("hand")} onOdds={to("odds")} onPack={to("pack")} />;
}

function StatsToolRoute({ tool }: { tool: "hand" | "odds" | "pack" }) {
  const { listId } = useParams();
  const back = useBack(`/library/list/${listId}/stats`);
  if (!listId) return <Navigate to="/library" replace />;
  if (tool === "hand") return <SampleHandScreen id={listId} onBack={back} />;
  if (tool === "odds") return <DrawOddsScreen id={listId} onBack={back} />;
  return <SamplePackScreen id={listId} onBack={back} />;
}

function LinePrintingRoute() {
  const { listId } = useParams();
  const [q] = useSearchParams();
  const back = useBack(`/library/list/${listId}`);
  if (!listId) return <Navigate to="/library" replace />;
  return <LinePrintingScreen id={listId} cardId={q.get("card") ?? ""} board={(q.get("board") ?? "main") as Board}
                             finish={(q.get("finish") ?? "nonfoil") as ListFinish} onDone={back} />;
}

function ListImportRoute() {
  const { kind } = useParams();
  const navigate = useNavigate();
  const back = useBack(kind === "cube" ? "/library/cubes" : "/library/decks");
  return <ListImportScreen kind={kind === "cube" ? "cube" : "deck"} onBack={back}
                           onCreated={(id) => navigate(`/library/list/${id}`, { replace: true })} />;
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

function TradesRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <TradesScreen onBack={back} onOpen={(id) => navigate(`/library/trade/${id}`)} onNew={() => navigate("/library/trade/new")} />;
}

function TradeRoute() {
  const { tradeId } = useParams();
  const back = useBack("/library/trades");
  const id = tradeId && tradeId !== "new" ? tradeId : null;
  // A new trade gets its id on first save; the address follows without a new history entry.
  return <TradeScreen key={id ?? "new"} id={id} onBack={back}
                      onSaved={(saved) => window.history.replaceState(window.history.state, "", `/library/trade/${saved}`)} />;
}

function StandingsRoute() {
  const { eventId } = useParams();
  if (!eventId) return <Navigate to="/" replace />;
  return <PublicStandings eventId={eventId} />;
}

/** Sends one redacted page view per navigation, including the first. */
function RouteAnalytics() {
  const location = useLocation();
  const last = useRef<string | null>(null);
  useEffect(() => {
    // StrictMode runs effects twice in dev; one view per address.
    const at = location.pathname + location.search;
    if (last.current === at) return;
    last.current = at;
    pageView(location.pathname, location.search, screenName(location.pathname, listKindOf));
  }, [location.pathname, location.search]);
  return null;
}

export default function App() {
  return (
    <BrowserRouter>
      <RouteAnalytics />
      <Suspense fallback={null}>
      <NameGate>
      <Routes>
        <Route path="/" element={<HomeRoute />} />
        <Route path="/e/:eventId" element={<OrganizerRoute />} />
        <Route path="/e/:eventId/add" element={<AddPlayersRoute />} />
        <Route path="/join/:code" element={<JoinRoute />} />
        <Route path="/j/:code" element={<QrJoinRoute />} />
        <Route path="/auth/confirm" element={<AuthConfirm />} />
        <Route path="/me" element={<ProfileRoute />} />
        <Route path="/sign-in" element={<SignInPage />} />
        <Route path="/privacy" element={<PrivacyPolicy />} />
        <Route path="/delete-account" element={<DeleteAccountPage />} />
        <Route path="/p/:eventId" element={<PlayerRoute />} />
        <Route path="/s/:eventId" element={<StandingsRoute />} />
        {import.meta.env.DEV && <Route path="/dev/events" element={<EventsDemo />} />}
        {import.meta.env.DEV && <Route path="/dev/roto" element={<RotoDemo />} />}
        <Route path="/library" element={<LibraryHomeRoute />} />
        <Route path="/library/cards" element={<AllCardsRoute />} />
        <Route path="/library/add" element={<AddCardsRoute />} />
        <Route path="/library/card/:oracleId" element={<CardDetailRoute />} />
        <Route path="/library/decks" element={<ListsRoute kind="deck" />} />
        <Route path="/library/find" element={<DeckFinderRoute />} />
        <Route path="/library/import" element={<CollectionImportRoute />} />
        <Route path="/library/import/:kind" element={<ListImportRoute />} />
        <Route path="/library/list/:listId/printing" element={<LinePrintingRoute />} />
        <Route path="/library/cubes" element={<ListsRoute kind="cube" />} />
        <Route path="/library/list/:listId" element={<ListRoute />} />
        <Route path="/library/list/:listId/add" element={<ListAddRoute />} />
        <Route path="/library/list/:listId/stats" element={<ListStatsRoute />} />
        <Route path="/library/list/:listId/stats/hand" element={<StatsToolRoute tool="hand" />} />
        <Route path="/library/list/:listId/stats/odds" element={<StatsToolRoute tool="odds" />} />
        <Route path="/library/list/:listId/stats/pack" element={<StatsToolRoute tool="pack" />} />
        <Route path="/library/list/:listId/versions" element={<VersionsRoute />} />
        <Route path="/library/list/:listId/v/:n" element={<VersionRoute />} />
        <Route path="/library/trades" element={<TradesRoute />} />
        <Route path="/library/binders" element={<BindersRoute />} />
        <Route path="/library/binder/:binderId" element={<BinderRoute />} />
        <Route path="/library/wants" element={<WantsRoute />} />
        <Route path="/library/trade/:tradeId" element={<TradeRoute />} />
        <Route path="/life" element={<LifeRoute />} />
        <Route path="/life/:matchId" element={<LifeRoute />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      </NameGate>
      </Suspense>
    </BrowserRouter>
  );
}
