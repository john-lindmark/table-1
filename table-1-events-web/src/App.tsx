import { Suspense, lazy, useEffect, useRef, useState, type ComponentType } from "react";
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
import { GoogleReturn } from "./screens/GoogleReturn";
import { DeleteAccountPage, PrivacyPolicy } from "./screens/Legal";
import { SignInPage } from "./screens/Landing";
import { NameGate } from "./components/NameGate";
import { DesktopShell } from "./components/DesktopShell";
import type { Board, ListFinish } from "./lib/lists";
import type { Condition } from "./lib/collection";
import { DueOffer } from "./components/PersonActions";
import type { RankJob } from "./lib/cubeRanking";
import type { CardContext } from "./screens/CardDetail";

/**
 * The Library (catalog, collection, decks and cubes) loads on first visit, so players who only use events never
 * download it. One import per module; Vite splits each into its own chunk.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function lazyNamed<M, K extends keyof M>(load: () => Promise<M>, name: K): M[K] {
  return lazy(() => load().then((m) => ({ default: m[name] as unknown as ComponentType<any> }))) as unknown as M[K];
}
const library = () => import("./screens/Library");
const discord = () => import("./screens/Discord");
const DiscordPage = lazyNamed(discord, "DiscordPage");
const DiscordLinkPage = lazyNamed(discord, "DiscordLinkPage");
const lists = () => import("./screens/Lists");
const LibraryHome = lazyNamed(library, "LibraryHome");
const AllCards = lazyNamed(library, "AllCards");
const AddCards = lazyNamed(library, "AddCards");
const CardDetail = lazyNamed(() => import("./screens/CardDetail"), "CardDetail");
const ListsScreen = lazyNamed(lists, "ListsScreen");
const NewListModal = lazyNamed(lists, "NewListModal");
const ListScreen = lazyNamed(lists, "ListScreen");
const ListAddScreen = lazyNamed(lists, "ListAddScreen");
const VersionsScreen = lazyNamed(lists, "VersionsScreen");
const VersionScreen = lazyNamed(lists, "VersionScreen");
const ChangePrintingScreen = lazyNamed(() => import("./screens/ChangePrinting"), "ChangePrintingScreen");
const listStats = () => import("./screens/ListStats");
const ListStatsScreen = lazyNamed(listStats, "ListStatsScreen");
const SampleHandScreen = lazyNamed(listStats, "SampleHandScreen");
const DrawOddsScreen = lazyNamed(listStats, "DrawOddsScreen");
const SamplePackScreen = lazyNamed(listStats, "SamplePackScreen");
const trades = () => import("./screens/Trades");
const TradesScreen = lazyNamed(trades, "TradesScreen");
const TradeScreen = lazyNamed(trades, "TradeScreen");
const binders = () => import("./screens/Binders");
const SharedLinkScreen = lazyNamed(() => import("./screens/Share"), "SharedLinkScreen");
const BindersScreen = lazyNamed(binders, "BindersScreen");
const BinderScreen = lazyNamed(binders, "BinderScreen");
const BinderEditor = lazyNamed(binders, "BinderEditor");
const WantsScreen = lazyNamed(binders, "WantsScreen");
const NearbyScreen = lazyNamed(() => import("./screens/Nearby"), "NearbyScreen");
const RedraftScreen = lazyNamed(() => import("./screens/Redraft"), "RedraftScreen");
const moderation = () => import("./screens/Moderation");
const NoticesScreen = lazyNamed(moderation, "NoticesScreen");
const ReviewScreen = lazyNamed(moderation, "ReviewScreen");
const friends = () => import("./screens/Friends");
const FriendsScreen = lazyNamed(friends, "FriendsScreen");
const FriendAddScreen = lazyNamed(friends, "FriendAddScreen");
const ProfileScreen = lazyNamed(friends, "ProfileScreen");
const ProfileCardsScreen = lazyNamed(friends, "ProfileCardsScreen");
const ProfileFriendsScreen = lazyNamed(friends, "ProfileFriendsScreen");
const SharingScreen = lazyNamed(friends, "SharingScreen");
const TradeMatchesScreen = lazyNamed(friends, "TradeMatchesScreen");
const TradeMatchScreen = lazyNamed(friends, "TradeMatchScreen");
const follows = () => import("./screens/Follows");
const FollowingScreen = lazyNamed(follows, "FollowingScreen");
const FollowChangesScreen = lazyNamed(follows, "FollowChangesScreen");
const rankings = () => import("./screens/Rankings");
const RankingsList = lazyNamed(rankings, "RankingsScreen");
const RankingOverview = lazyNamed(rankings, "RankingScreen");
const RankingPick = lazyNamed(rankings, "RankingPickScreen");
const RankingLists = lazyNamed(rankings, "RankingListsScreen");
const RankingCard = lazyNamed(rankings, "RankingCardScreen");
const RankingCompare = lazyNamed(rankings, "RankingCompareScreen");
const RankingPack = lazyNamed(rankings, "RankingPackScreen");
const RankingChanges = lazyNamed(rankings, "RankingChangesScreen");
const DeckFinderScreen = lazyNamed(() => import("./screens/DeckFinder"), "DeckFinderScreen");
const DeckPhotosScreen = lazyNamed(() => import("./screens/DeckPhotos"), "DeckPhotosScreen");
const MyDeckPhotosScreen = lazyNamed(() => import("./screens/DeckPhotos"), "MyDeckPhotosScreen");
const SupportHome = lazyNamed(() => import("./screens/Support"), "SupportHome");
const SupportTopicScreen = lazyNamed(() => import("./screens/Support"), "SupportTopicScreen");
const SupportFaqScreen = lazyNamed(() => import("./screens/Support"), "SupportFaqScreen");
const SupportGuideScreen = lazyNamed(() => import("./screens/Support"), "SupportGuideScreen");
const SupportGuideIndex = lazyNamed(() => import("./screens/Support"), "SupportGuideIndex");
const ListImportScreen = lazyNamed(() => import("./screens/ListImport"), "ListImportScreen");
const CubeSyncScreen = lazyNamed(() => import("./screens/CubeSync"), "CubeSyncScreen");
const insights = () => import("./screens/Insights");
const InsightsHome = lazyNamed(insights, "InsightsHome");
const InsightsArchetype = lazyNamed(insights, "InsightsArchetype");
const InsightsCard = lazyNamed(insights, "InsightsCard");
const InsightsCardSearch = lazyNamed(insights, "InsightsCardSearch");
const InsightsBan = lazyNamed(insights, "InsightsBan");
const InsightsMatchups = lazyNamed(insights, "InsightsMatchups");
const InsightsPart = lazyNamed(insights, "InsightsPart");
const InsightsPair = lazyNamed(insights, "InsightsPair");
const InsightsLimitedCard = lazyNamed(insights, "InsightsLimitedCard");
const InsightsReview = lazyNamed(insights, "InsightsReview");
const CollectionImportScreen = lazyNamed(() => import("./screens/CollectionImport"), "CollectionImportScreen");
const EventsDemo = lazyNamed(() => import("./screens/EventsDemo"), "EventsDemo");
// Dev only: production builds drop the demo and its fixture.
const RotoDemo = import.meta.env.DEV ? lazyNamed(() => import("./screens/RotoDemo"), "RotoDemo") : () => null;
const SpotsDev = import.meta.env.DEV ? lazyNamed(() => import("./screens/SpotsDev"), "SpotsDev") : () => null;

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
      onNearby={() => navigate("/nearby")}
    />
  );
}

function NearbyRoute() {
  const navigate = useNavigate();
  return <NearbyScreen onBack={useBack("/")} onOpen={(id) => navigate(`/p/${id}`)} />;
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
      onOpenPhotos={() => navigate(`/e/${eventId}/photos`)}
      onOpenRedraft={(setCode) => navigate(`/e/${eventId}/redraft`, { state: { setCode } })}
    />
  );
}

/** /e/:eventId/photos from the organizer screen, /p/:eventId/photos from a player's. */
function DeckPhotosRoute({ organizer }: { organizer: boolean }) {
  const { eventId } = useParams();
  const back = useBack(organizer ? `/e/${eventId}` : `/p/${eventId}`);
  if (!eventId) return <Navigate to="/" replace />;
  return <DeckPhotosScreen eventId={eventId} organizer={organizer} onBack={back} />;
}

/** /e/:eventId/redraft and /p/:eventId/redraft: a finished set draft's redraft pile. */
function RedraftRoute({ organizer }: { organizer: boolean }) {
  const { eventId } = useParams();
  const setCode = (useLocation().state as { setCode?: string | null } | null)?.setCode ?? null;
  const back = useBack(organizer ? `/e/${eventId}` : `/p/${eventId}`);
  if (!eventId) return <Navigate to="/" replace />;
  return <RedraftScreen eventId={eventId} setCode={setCode} onBack={back} />;
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
  const back = useBack("/");
  return <PlayerView code={code} onBack={back} onOpenLife={(matchId) => navigate(`/life/${matchId}`)}
                     onOpenPhotos={(id) => navigate(`/p/${id}/photos`)}
                     onOpenRedraft={(id, setCode) => navigate(`/p/${id}/redraft`, { state: { setCode } })} />;
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
  return <Profile onSignedOut={() => navigate("/")} onFriends={() => navigate("/friends")} onSharing={() => navigate("/sharing")}
                  onProfile={(id) => navigate(`/u/${id}`)} onDiscord={() => navigate("/discord")}
                  onNotices={() => navigate("/me/notices")} onReview={() => navigate("/me/review")}
                  onDeckPhotos={() => navigate("/me/deck-photos")} onSupport={() => navigate("/support")} />;
}

/* Support (contract/support-2026-11-10.md): /support, signed in or out; a topic, an answer, a guide section
   (?e=<entry> scrolls to the entry a search found; ?from= says how it was reached, for telemetry). */
function useSupportGo() {
  const navigate = useNavigate();
  return {
    topic: (key: string) => navigate(`/support/topic/${key}`),
    guides: () => navigate("/support/guide"),
    faq: (id: string, from: string) => navigate(`/support/faq/${id}?from=${from}`),
    guide: (section: string, entry: string | null, from: string) =>
      navigate(`/support/guide/${section}?from=${from}${entry ? `&e=${entry}` : ""}`),
  };
}
function SupportRoute() {
  return <SupportHome onBack={useBack("/me")} go={useSupportGo()} />;
}
function SupportTopicRoute() {
  const { key = "" } = useParams();
  return <SupportTopicScreen topic={key} onBack={useBack("/support")} go={useSupportGo()} />;
}
function SupportFaqRoute() {
  const { id = "" } = useParams();
  const from = new URLSearchParams(useLocation().search).get("from") ?? "link";
  return <SupportFaqScreen id={id} from={from} onBack={useBack("/support")} go={useSupportGo()} />;
}
function SupportGuideIndexRoute() {
  return <SupportGuideIndex onBack={useBack("/support")} go={useSupportGo()} />;
}
function SupportGuideRoute() {
  const { section = "" } = useParams();
  const params = new URLSearchParams(useLocation().search);
  return <SupportGuideScreen section={section} entry={params.get("e")} from={params.get("from") ?? "link"} onBack={useBack("/support")} />;
}

/** /me/deck-photos: every photo of your decks (Account → Deck photos). */
function MyDeckPhotosRoute() {
  const navigate = useNavigate();
  return <MyDeckPhotosScreen onBack={useBack("/me")} onOpenEvent={(id) => navigate(`/p/${id}`)}
                             onOpenEventPhotos={(id) => navigate(`/p/${id}/photos`)} />;
}

function NoticesRoute() {
  return <NoticesScreen onBack={useBack("/me")} />;
}
function ReviewRoute() {
  return <ReviewScreen onBack={useBack("/me")} />;
}

function DiscordRoute() {
  const back = useBack("/me");
  return <DiscordPage onBack={back} />;
}

function PlayerRoute() {
  const { eventId } = useParams();
  const navigate = useNavigate();
  const back = useBack("/");
  return <PlayerView eventIdProp={eventId} onBack={back} onOpenLife={(matchId) => navigate(`/life/${matchId}`)}
                     onOpenPhotos={(id) => navigate(`/p/${id}/photos`)}
                     onOpenRedraft={(id, setCode) => navigate(`/p/${id}/redraft`, { state: { setCode } })} />;
}

/** /life is the local tracker (no event); /life/:matchId is the shared tracker for a match. */
function LifeRoute() {
  const { matchId } = useParams();
  const back = useBack("/");
  return <LifeTracker key={matchId ?? "local"} matchId={matchId} onClose={back} />;
}

function LibraryHomeRoute() {
  const navigate = useNavigate();
  const [creating, setCreating] = useState<"deck" | "cube" | "binder" | null>(null);
  return (
    <>
      <LibraryHome go={(href) => navigate(href)} onNew={setCreating} />
      {(creating === "deck" || creating === "cube") && (
        <NewListModal kind={creating} onClose={() => setCreating(null)} onCreated={(id) => navigate(`/library/list/${id}`)}
                      onFind={() => navigate("/library/find")} onImport={() => navigate(`/library/import/${creating}`)} />
      )}
      {creating === "binder" && <BinderEditor binder={null} onClose={() => setCreating(null)} onSaved={(b) => navigate(`/library/binder/${b.id}`)} />}
    </>
  );
}

/* Friends, profiles, sharing and trade matches (contract/friends-sharing-2026-10-18.md). */
function FriendsRoute() {
  const navigate = useNavigate();
  const back = useBack("/me");
  return <FriendsScreen onBack={back} onProfile={(id) => navigate(`/u/${id}`)} onAdd={() => navigate("/friends/add")} />;
}
function FriendAddRoute() {
  return <FriendAddScreen onBack={useBack("/friends")} />;
}
function ProfileUserRoute() {
  const { userId } = useParams();
  const navigate = useNavigate();
  // A shared profile link lands under Account, as in the apps (testdata/universal-links/cases.json).
  const back = useBack("/me");
  if (!userId) return <Navigate to="/friends" replace />;
  return <ProfileScreen userId={userId} onBack={back} onSharing={() => navigate("/sharing")}
                        onMatch={() => navigate(`/library/match/${userId}`)} onFriends={() => navigate(`/u/${userId}/friends`)}
                        onSection={(kind, id) => navigate(`/u/${userId}/${kind}${id ? `/${id}` : ""}`)} />;
}
function ProfileFriendsRoute() {
  const { userId } = useParams();
  const navigate = useNavigate();
  const back = useBack(`/u/${userId}`);
  if (!userId) return <Navigate to="/friends" replace />;
  return <ProfileFriendsScreen userId={userId} onBack={back} onProfile={(id) => navigate(`/u/${id}`)} />;
}
function ProfileCardsRoute() {
  const { userId, section, itemId } = useParams();
  const navigate = useNavigate();
  const back = useBack(`/u/${userId}`);
  const kinds = ["all_cards", "for_trade", "wants", "binder", "deck", "cube"] as const;
  const kind = kinds.find((k) => k === section);
  if (!userId || !kind) return <Navigate to="/friends" replace />;
  return <ProfileCardsScreen userId={userId} section={kind} item={itemId ?? null} onBack={back}
                             onCard={(o) => navigate(`/library/card/${o}`, { state: { search: true } })} onList={(id) => navigate(`/library/list/${id}`)}
                             onRankings={(id) => navigate(`/library/list/${id}/rankings`)}
                             onFollowChanges={(k, id) => navigate(`/library/following/${k}/${id}`)} />;
}
/* Following (contract/follows-2026-10-25.md). */
function FollowingRoute() {
  const navigate = useNavigate();
  return <FollowingScreen onBack={useBack("/library")} onOpen={(href) => navigate(href)} />;
}
function FollowChangesRoute() {
  const { kind, itemId } = useParams();
  const navigate = useNavigate();
  const back = useBack("/library/following");
  if (!itemId || (kind !== "binder" && kind !== "deck" && kind !== "cube")) return <Navigate to="/library/following" replace />;
  return <FollowChangesScreen kind={kind} id={itemId} onBack={back} onCard={(o) => navigate(`/library/card/${o}`, { state: { search: true } })} />;
}
function SharingRoute() {
  return <SharingScreen onBack={useBack("/me")} />;
}
function TradeMatchesRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <TradeMatchesScreen onBack={back} onOpen={(id) => navigate(`/library/match/${id}`)}
                             onFriends={() => navigate("/friends")} onSharing={() => navigate("/sharing")} />;
}
function TradeMatchRoute() {
  const { userId } = useParams();
  const navigate = useNavigate();
  const back = useBack("/library/matches");
  if (!userId) return <Navigate to="/library/matches" replace />;
  return <TradeMatchScreen userId={userId} onBack={back} onProfile={() => navigate(`/u/${userId}`)}
                           onCard={(o) => navigate(`/library/card/${o}`, { state: { search: true } })} onTrade={(id) => navigate(`/library/trade/${id}`)} />;
}
function BindersRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <BindersScreen onBack={back} onOpen={(id) => navigate(`/library/binder/${id}`)} onCard={(o) => navigate(`/library/card/${o}`)} />;
}

function BinderRoute() {
  const { binderId } = useParams();
  const navigate = useNavigate();
  const back = useBack("/library/binders");
  if (!binderId) return <Navigate to="/library/binders" replace />;
  return <BinderScreen key={binderId} id={binderId} onBack={back} onCard={(o) => navigate(`/library/card/${o}`, { state: { binder: binderId } })} />;
}

function WantsRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <WantsScreen onBack={back} onCard={(o) => navigate(`/library/card/${o}`, { state: { search: true } })}
                      onBuy={(what) => navigate(`/library/buy/${what}`)} />;
}

const BuyScreen = lazyNamed(() => import("./screens/Buy"), "BuyScreen");
/** The Buy screen (contract/buy-2026-11-06.md): a deck or cube, Wants or Missing. */
function BuyRoute({ what }: { what?: "wants" | "missing" }) {
  const { listId } = useParams();
  const navigate = useNavigate();
  const back = useBack(listId ? `/library/list/${listId}` : "/library/wants");
  const source = what ?? (listId ? { list: listId } : null);
  if (!source) return <Navigate to="/library" replace />;
  return <BuyScreen source={source} onBack={back} onCard={(o) => navigate(`/library/card/${o}`, { state: { search: true } })} />;
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

function CardSearchRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <AddCards search onBack={back} onOpen={(id) => navigate(`/library/card/${id}`)} go={(path) => navigate(path)} />;
}

function CardDetailRoute() {
  const { oracleId } = useParams();
  const back = useBack("/library/cards");
  // Opened from a deck/cube or a binder: in the history state, so no row id lands in the URL.
  const state = useLocation().state as CardContext | null;
  if (!oracleId) return <Navigate to="/library" replace />;
  const navigate = useNavigate();
  return <CardDetail key={oracleId} oracleId={oracleId} onBack={back} context={state?.list || state?.binder || state?.search ? state : undefined}
                     onList={(id) => navigate(`/library/list/${id}`)} />;
}

function ListsRoute({ kind }: { kind: "deck" | "cube" }) {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <ListsScreen key={kind} kind={kind} onBack={back} onOpen={(id) => navigate(`/library/list/${id}`)}
                      onFind={() => navigate("/library/find")} onImport={() => navigate(`/library/import/${kind}`)}
                      onRankings={() => navigate("/library/rankings")} />;
}

function ListRoute() {
  const { listId } = useParams();
  const navigate = useNavigate();
  const back = useBack("/library/decks");
  if (!listId) return <Navigate to="/library" replace />;
  return (
    <ListScreen id={listId} onBack={back} onCard={(o) => navigate(`/library/card/${o}`, { state: { list: listId } })}
                onAdd={() => navigate(`/library/list/${listId}/add`)} onVersions={() => navigate(`/library/list/${listId}/versions`)}
                onOpen={(id) => navigate(`/library/list/${id}`)}
                onPrinting={(card, board, finish, lang, cond) => navigate(`/library/list/${listId}/printing?card=${card}&board=${board}&finish=${finish}&lang=${lang}${cond !== "NM" ? `&cond=${cond}` : ""}`)}
                onStats={() => navigate(`/library/list/${listId}/stats`)} onRankings={() => navigate(`/library/list/${listId}/rankings`)}
                onSync={() => navigate(`/library/list/${listId}/sync`)} onGuide={() => navigate(`/library/list/${listId}/guide`)}
                onBuy={() => navigate(`/library/list/${listId}/buy`)} />
  );
}

const SideboardGuideScreen = lazyNamed(() => import("./screens/SideboardGuide"), "SideboardGuideScreen");
/** A deck's sideboard guide and its screens (contract/sideboard-guide-2026-11-04.md). */
function SideboardGuideRoute({ page }: { page: "guide" | "new" | "print" | "pool" | "matchup" | "pick" }) {
  const { listId, matchupId, side } = useParams();
  const navigate = useNavigate();
  const base = `/library/list/${listId}/guide`;
  const back = useBack(page === "guide" ? `/library/list/${listId}` : page === "pick" ? `${base}/m/${matchupId}` : base);
  if (!listId) return <Navigate to="/library" replace />;
  const at = page === "matchup" ? { page, id: matchupId ?? "" } as const
    : page === "pick" ? { page, id: matchupId ?? "", side: side === "out" ? "out" as const : "in" as const } : { page };
  return <SideboardGuideScreen id={listId} at={at} onBack={back} go={(path, replace) => navigate(`${base}/${path}`, { replace })} />;
}

function CubeSyncRoute() {
  const { listId } = useParams();
  const navigate = useNavigate();
  const back = useBack(`/library/list/${listId}`);
  if (!listId) return <Navigate to="/library" replace />;
  return <CubeSyncScreen id={listId} onBack={back} onCard={(o) => navigate(`/library/card/${o}`, { state: { list: listId } })} />;
}

const RankingsScreens = lazyNamed(rankings, "RankingsDemoGate");
function rankingGo(navigate: ReturnType<typeof useNavigate>, id: string) {
  return (path: string, replace = false) => navigate(`/library/ranking/${id}/${path}`, { replace });
}
/** A ranking subject's Rankings: a cube's, or a Limited set's ("set:FRA", contract/cube-rankings-2026-10-21.md § Sets) under Insights. */
const subjectRankings = (id: string) => (id.startsWith("set:") ? `/insights/limited/${encodeURIComponent(id.slice(4))}/rankings` : `/library/list/${id}/rankings`);
function RankingsRoute() {
  const { listId, set } = useParams();
  const navigate = useNavigate();
  const subject = set ? `set:${set.toUpperCase()}` : listId ?? null;
  const back = useBack(set ? "/insights/limited" : listId ? `/library/list/${listId}` : "/library/cubes");
  return <RankingsScreens><RankingsList key={subject ?? "mine"} listId={subject} onBack={back} onOpen={(id) => navigate(`/library/ranking/${id}`)}
                                        onCube={(id) => navigate(subjectRankings(id))} /></RankingsScreens>;
}
function RankingRoute() {
  const { rankingId, job, oracleId, otherId } = useParams();
  const navigate = useNavigate();
  const loc = useLocation();
  const base = `/library/ranking/${rankingId}`;
  const back = useBack(loc.pathname === base ? "/library/cubes" : base);
  if (!rankingId) return <Navigate to="/library" replace />;
  const go = rankingGo(navigate, rankingId);
  const j = (job ?? "F") as RankJob;
  const part = loc.pathname.slice(base.length).split("/")[1] ?? "";
  const screen = part === "screen" ? <RankingPick id={rankingId} job={j} onBack={back} go={go} />
    : part === "lists" ? <RankingLists id={rankingId} job={j} onBack={back} go={go} />
    : part === "card" && oracleId ? <RankingCard id={rankingId} oracleId={oracleId} job={j} onBack={back} go={go} />
    : part === "compare" && otherId ? <RankingCompare id={rankingId} otherId={otherId} job={j} onBack={back} go={go} />
    : part === "pack" ? <RankingPack id={rankingId} onBack={back} go={go} />
    : part === "changes" ? <RankingChanges id={rankingId} onBack={back} go={go} />
    : <RankingOverview id={rankingId} onBack={back} go={go} />;
  return <RankingsScreens>{screen}</RankingsScreens>;
}

function ListStatsRoute() {
  const { listId } = useParams();
  const navigate = useNavigate();
  const back = useBack(`/library/list/${listId}`);
  if (!listId) return <Navigate to="/library" replace />;
  const to = (page: string) => () => navigate(`/library/list/${listId}/stats/${page}`);
  return <ListStatsScreen id={listId} onBack={back} onHand={to("hand")} onOdds={to("odds")} onPack={to("pack")}
                          onCard={(o) => navigate(`/library/card/${o}`)} />;
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
  return <ChangePrintingScreen target={{ kind: "list", listId, cardId: q.get("card") ?? "", board: (q.get("board") ?? "main") as Board,
                                        finish: (q.get("finish") ?? "nonfoil") as ListFinish, lang: q.get("lang") ?? "en",
                                        cond: (q.get("cond") ?? "NM") as Condition }} onClose={back} />;
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
  return <ListAddScreen id={listId} onDone={back} onCard={(o) => navigate(`/library/card/${o}`, { state: { list: listId } })} />;
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
  return <VersionScreen id={listId} number={Number(n)} onBack={back} onCard={(o) => navigate(`/library/card/${o}`, { state: { list: listId } })} />;
}

function TradesRoute() {
  const navigate = useNavigate();
  const back = useBack("/library");
  return <TradesScreen onBack={back} onOpen={(id) => navigate(`/library/trade/${id}`)} onNew={() => navigate("/library/trade/new")}
                       onMatch={(id) => navigate(`/library/match/${id}`)} onMatches={() => navigate("/library/matches")} />;
}

function TradeRoute() {
  const { tradeId } = useParams();
  const back = useBack("/library/trades");
  const id = tradeId && tradeId !== "new" ? tradeId : null;
  // A new trade gets its id on first save; the address follows without a new history entry.
  return <TradeScreen key={id ?? "new"} id={id} onBack={back}
                      onSaved={(saved) => window.history.replaceState(window.history.state, "", `/library/trade/${saved}`)} />;
}

/** A share link (contract/share-links-2026-10-23.md): signed in or out. */
function SharedLinkRoute() {
  const { token } = useParams();
  const navigate = useNavigate();
  const back = useBack("/");
  if (!token) return <Navigate to="/" replace />;
  return <SharedLinkScreen token={token} onBack={back} onCard={(o) => navigate(`/library/card/${o}`, { state: { search: true } })}
                           onList={(id) => navigate(`/library/list/${id}`)} onSignIn={() => navigate("/sign-in")}
                           onFollowChanges={(k, id) => navigate(`/library/following/${k}/${id}`)}
                           onRankings={(id) => navigate(`/library/list/${id}/rankings`)} />;
}

function StandingsRoute() {
  const { eventId } = useParams();
  const back = useBack("/");
  if (!eventId) return <Navigate to="/" replace />;
  return <PublicStandings eventId={eventId} onBack={back} />;
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
      <DesktopShell>
      <Routes>
        <Route path="/" element={<HomeRoute />} />
        <Route path="/e/:eventId" element={<OrganizerRoute />} />
        <Route path="/e/:eventId/add" element={<AddPlayersRoute />} />
        <Route path="/e/:eventId/photos" element={<DeckPhotosRoute organizer />} />
        <Route path="/e/:eventId/redraft" element={<RedraftRoute organizer />} />
        <Route path="/p/:eventId/redraft" element={<RedraftRoute organizer={false} />} />
        <Route path="/join/:code" element={<JoinRoute />} />
        <Route path="/j/:code" element={<QrJoinRoute />} />
        <Route path="/auth/confirm" element={<AuthConfirm />} />
        <Route path="/auth/google" element={<GoogleReturn />} />
        <Route path="/discord" element={<DiscordRoute />} />
        <Route path="/discord/link" element={<DiscordLinkPage />} />
        <Route path="/nearby" element={<NearbyRoute />} />
        <Route path="/me" element={<ProfileRoute />} />
        <Route path="/me/notices" element={<NoticesRoute />} />
        <Route path="/me/deck-photos" element={<MyDeckPhotosRoute />} />
        <Route path="/me/review" element={<ReviewRoute />} />
        <Route path="/support" element={<SupportRoute />} />
        <Route path="/support/topic/:key" element={<SupportTopicRoute />} />
        <Route path="/support/faq/:id" element={<SupportFaqRoute />} />
        <Route path="/support/guide" element={<SupportGuideIndexRoute />} />
        <Route path="/support/guide/:section" element={<SupportGuideRoute />} />
        <Route path="/sign-in" element={<SignInPage />} />
        <Route path="/privacy" element={<PrivacyPolicy />} />
        <Route path="/delete-account" element={<DeleteAccountPage />} />
        <Route path="/p/:eventId" element={<PlayerRoute />} />
        <Route path="/p/:eventId/photos" element={<DeckPhotosRoute organizer={false} />} />
        <Route path="/s/:eventId" element={<StandingsRoute />} />
        <Route path="/l/:token" element={<SharedLinkRoute />} />
        {import.meta.env.DEV && <Route path="/dev/events" element={<EventsDemo />} />}
        {import.meta.env.DEV && <Route path="/dev/roto" element={<RotoDemo />} />}
        {import.meta.env.DEV && <Route path="/dev/spots" element={<SpotsDev />} />}
        <Route path="/library" element={<LibraryHomeRoute />} />
        <Route path="/library/cards" element={<AllCardsRoute />} />
        <Route path="/library/add" element={<AddCardsRoute />} />
        <Route path="/library/search" element={<CardSearchRoute />} />
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
        <Route path="/library/list/:listId/sync" element={<CubeSyncRoute />} />
        <Route path="/library/list/:listId/buy" element={<BuyRoute />} />
        <Route path="/library/buy/wants" element={<BuyRoute what="wants" />} />
        <Route path="/library/buy/missing" element={<BuyRoute what="missing" />} />
        <Route path="/library/list/:listId/guide" element={<SideboardGuideRoute page="guide" />} />
        <Route path="/library/list/:listId/guide/new" element={<SideboardGuideRoute page="new" />} />
        <Route path="/library/list/:listId/guide/print" element={<SideboardGuideRoute page="print" />} />
        <Route path="/library/list/:listId/guide/pool" element={<SideboardGuideRoute page="pool" />} />
        <Route path="/library/list/:listId/guide/m/:matchupId" element={<SideboardGuideRoute page="matchup" />} />
        <Route path="/library/list/:listId/guide/m/:matchupId/:side" element={<SideboardGuideRoute page="pick" />} />
        <Route path="/library/list/:listId/rankings" element={<RankingsRoute />} />
        <Route path="/library/rankings" element={<RankingsRoute />} />
        <Route path="/library/ranking/:rankingId" element={<RankingRoute />} />
        <Route path="/library/ranking/:rankingId/screen/:job" element={<RankingRoute />} />
        <Route path="/library/ranking/:rankingId/lists/:job" element={<RankingRoute />} />
        <Route path="/library/ranking/:rankingId/card/:oracleId/:job" element={<RankingRoute />} />
        <Route path="/library/ranking/:rankingId/compare/:otherId/:job" element={<RankingRoute />} />
        <Route path="/library/ranking/:rankingId/pack" element={<RankingRoute />} />
        <Route path="/library/ranking/:rankingId/changes" element={<RankingRoute />} />
        <Route path="/library/list/:listId/stats/hand" element={<StatsToolRoute tool="hand" />} />
        <Route path="/library/list/:listId/stats/odds" element={<StatsToolRoute tool="odds" />} />
        <Route path="/library/list/:listId/stats/pack" element={<StatsToolRoute tool="pack" />} />
        <Route path="/library/list/:listId/versions" element={<VersionsRoute />} />
        <Route path="/library/list/:listId/v/:n" element={<VersionRoute />} />
        <Route path="/library/trades" element={<TradesRoute />} />
        <Route path="/library/binders" element={<BindersRoute />} />
        <Route path="/library/binder/:binderId" element={<BinderRoute />} />
        <Route path="/library/wants" element={<WantsRoute />} />
        <Route path="/library/matches" element={<TradeMatchesRoute />} />
        <Route path="/library/match/:userId" element={<TradeMatchRoute />} />
        <Route path="/library/following" element={<FollowingRoute />} />
        <Route path="/library/following/:kind/:itemId" element={<FollowChangesRoute />} />
        <Route path="/friends" element={<FriendsRoute />} />
        <Route path="/friends/add" element={<FriendAddRoute />} />
        <Route path="/sharing" element={<SharingRoute />} />
        <Route path="/u/:userId" element={<ProfileUserRoute />} />
        <Route path="/u/:userId/:section" element={<ProfileCardsRoute />} />
        <Route path="/u/:userId/friends" element={<ProfileFriendsRoute />} />
        <Route path="/u/:userId/:section/:itemId" element={<ProfileCardsRoute />} />
        <Route path="/library/trade/:tradeId" element={<TradeRoute />} />
        <Route path="/insights" element={<InsightsHome section="constructed" />} />
        <Route path="/insights/limited" element={<InsightsHome section="limited" />} />
        <Route path="/insights/review" element={<InsightsReview />} />
        <Route path="/insights/limited/:set/rankings" element={<RankingsRoute />} />
        <Route path="/insights/limited/:set/:event/:group/pair/:pair" element={<InsightsPair />} />
        <Route path="/insights/limited/:set/:event/:group/card/:name" element={<InsightsLimitedCard />} />
        <Route path="/insights/:format/archetype/:id" element={<InsightsArchetype />} />
        <Route path="/insights/:format/archetype/:id/finish/:i" element={<InsightsArchetype />} />
        <Route path="/insights/:format/card/:oracleId" element={<InsightsCard />} />
        <Route path="/insights/:format/card/:oracleId/list/:i" element={<InsightsCard />} />
        <Route path="/insights/:format/cards" element={<InsightsCardSearch />} />
        <Route path="/insights/:format/ban/:id" element={<InsightsBan />} />
        <Route path="/insights/:format/matchups" element={<InsightsMatchups />} />
        <Route path="/insights/:format/part/:part" element={<InsightsPart />} />
        <Route path="/life" element={<LifeRoute />} />
        <Route path="/life/:matchId" element={<LifeRoute />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      <DueOffer />
      </DesktopShell>
      </NameGate>
      </Suspense>
    </BrowserRouter>
  );
}
