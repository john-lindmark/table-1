import { currentFix, setEventLocation } from "../lib/nearby";
import { JOIN_NOTICE } from "../lib/joinPreview";
import { Suspense, lazy, useCallback, useEffect, useRef, useState } from "react";
import { Link, useLocation } from "react-router-dom";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabaseClient";
import {
  createEventV2,
  setEventPods,
  fetchEventsHome,
  savedEventsHome,
  formatLabelOf,
  fetchLiveSnapshots,
  reportFromHome,
  respondToInvite,
  respondToResult,
  errorMessage,
  myDisplayName,
} from "../lib/api";
import type { DraftableSet, FormatName, HomeData, HomeEvent, HomeInvite, LiveSnapshot, TrackerMode } from "../lib/types";
import { JoinByCode } from "../components/JoinByCode";
import { Landing } from "./Landing";
import { FormatPicker, PlayersEditor, ProductPicker, RoundTimerSwitch, cubeUrlProblem } from "../components/EventFormFields";
import { when } from "../lib/scheduledEvents";
import { fetchEventsFollowed, followedDetail, type FollowedEvent } from "../lib/eventFollows";
import { CutAndRoundsFields, DecklistsFields, DraftPodFields, ScheduleFields, type DecklistMode, type ScheduleValue } from "../components/EventExtras";
import { draftAutoLabel, type PodPairing } from "../lib/draftPods";
import { defaultPairing } from "../lib/rotoMath";
import { RotoPairingFields, linkRotoCube } from "./roto/lazy";
import { claimAutoOpen, useTrackerMode } from "../lib/settings";
import { eventNamePreview, isTeamFormat, typeOfFormat } from "../lib/formats";
import { useDesktop } from "../lib/desktop";
import { ageOf, isNetworkError, offlineNotice } from "../lib/offline";
import { capture } from "../lib/telemetry";
import { BAR_ICON, Icon } from "../components/icons";
import { TextPanel } from "../components/EventListing";
import { ADDRESS_MAX, DESCRIPTION_MAX, FIND_PICKS, counter, demoPath, eventListingSet, listingsLive, type FindPick } from "../lib/leagues";
import {
  Bar,
  BigAction,
  Columns,
  Countdown,
  Field,
  GhostAction,
  Notice,
  Row,
  Screen,
  Section,
  Segmented,
  Stat,
  TabNav,
  shortWhen,
} from "../components/kit";

/** Find events under your own (contract/public-events-leagues-2026-11-13.md § 1): its own chunk, drawn only when the
 *  server lists events. */
const FindEventsSection = lazy(() => import("./Find").then((m) => ({ default: m.FindEventsSection })));

/** Dev server, `/?demo`: the Events home on stand-in events, to look at Find events without an account. */
const DEMO_HOME: HomeData = {
  events: [{
    id: "demo-ev-fri", name: "Friday draft", status: "setup", bucket: "upcoming", organizing: false, playing: true, current_round: 0,
    number_of_rounds: 3, players: 5, capacity: 8, format_label: "Draft", starts_at: new Date(Date.now() + 2 * 86_400_000).toISOString(),
  } as unknown as HomeEvent],
  invites: [],
};

/**
 * The Events tab. What's happening now comes first and biggest; joining and creating are secondary
 * until there's nothing to show.
 */
export function Home({
  onOpenEvent,
  onOpenPlayer,
  onAddPlayers,
  onOpenLife,
  onNearby,
}: {
  onOpenEvent: (eventId: string) => void;
  /** Open events within 150 m (the browser asks for location there). */
  onNearby?: () => void;
  onOpenPlayer: (eventId: string) => void;
  onAddPlayers: (eventId: string) => void;
  /** No match id: the local tracker. */
  onOpenLife: (matchId?: string) => void;
}) {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const demoHome = import.meta.env.DEV && new URLSearchParams(useLocation().search).has("demo");
  const [data, setData] = useState<HomeData | null>(demoHome ? DEMO_HOME : null);
  const [followed, setFollowed] = useState<FollowedEvent[]>([]);
  const [snaps, setSnaps] = useState<Record<string, LiveSnapshot>>({});
  const [showPast, setShowPast] = useState(false);
  const [error, setError] = useState<string | null>(null);
  /** "Couldn't refresh · last updated …" while what's shown is the saved copy (contract/offline-2026-10-31.md § 1). */
  const [stale, setStale] = useState<string | null>(null);
  const savedAt = useRef<number | null>(null);
  const [creating, setCreating] = useState(false);
  const { mode } = useTrackerMode();
  const desktop = useDesktop();

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  const load = useCallback(async () => {
    // What this account last saw shows at once; the server's answer replaces it.
    if (savedAt.current === null) {
      const saved = await savedEventsHome();
      if (saved && savedAt.current === null) {
        savedAt.current = saved.at;
        setData((d) => d ?? saved.value);
      }
    }
    try {
      setData(await fetchEventsHome());
      savedAt.current = Date.now();
      setError(null);
      setStale(null);
    } catch (e) {
      const age = ageOf(savedAt.current);
      const n = offlineNotice(true, age, errorMessage(e));
      if (n && !n.isError) {
        setStale(n.text);
        if (isNetworkError(e)) capture("offline_shown", { screen: "home", age_s: age ?? 0 });
      } else {
        setError(n?.text ?? errorMessage(e));
        setData((d) => d ?? { events: [], invites: [] });
      }
    }
    // Events you follow but aren't in (contract/event-follows-2026-11-09.md).
    setFollowed(await fetchEventsFollowed());
    const live = await fetchLiveSnapshots();
    setSnaps(Object.fromEntries(live.map((s) => [s.eventId, s])));
  }, []);

  useEffect(() => {
    if (session && !demoHome) load();
  }, [session, load, demoHome]);

  const live = data?.events.filter((e) => e.bucket === "live") ?? [];
  const upcoming = data?.events.filter((e) => e.bucket === "upcoming") ?? [];
  const past = data?.events.filter((e) => e.bucket === "past") ?? [];
  const invites = data?.invites ?? [];

  // While something is live, keep the cards fresh; the clocks themselves tick locally.
  const liveKey = live.map((e) => e.id).join(",");
  useEffect(() => {
    if (!liveKey) return;
    const id = window.setInterval(load, 45_000);
    return () => window.clearInterval(id);
  }, [liveKey, load]);

  // Tracker mode: a round you're playing opens straight into the life tracker (once per match).
  const openLifeRef = useRef(onOpenLife);
  openLifeRef.current = onOpenLife;
  useEffect(() => {
    if (mode !== "tracker" || creating) return;
    const playing = Object.values(snaps).find(
      (s) => s.state.phase === "playing" && s.state.matchId && s.state.mySide != null && s.state.status === "pending",
    );
    if (playing?.state.matchId && claimAutoOpen(playing.state.matchId)) openLifeRef.current(playing.state.matchId);
  }, [mode, snaps, creating]);

  if (!ready) {
    return (
      <Screen>
        <div className="flex-1 flex items-center justify-center t1-label">Loading…</div>
      </Screen>
    );
  }

  if (!session && !demoHome) return <Landing />;

  if (creating) {
    return (
      <NewEvent
        onCancel={() => setCreating(false)}
        onCreated={(id) => {
          setCreating(false);
          onAddPlayers(id);
        }}
      />
    );
  }

  const open = (e: HomeEvent) => (e.organizing ? onOpenEvent(e.id) : onOpenPlayer(e.id));
  const empty = data !== null && data.events.length === 0 && invites.length === 0 && !(data.waitlist ?? []).length && !followed.length;
  // Live, invitations, (Join,) upcoming and past: the whole page on a phone, the left column on a desktop.
  const lists = (
    <>
      {live.map((e) =>
        e.playing && !e.organizing ? (
          <PlayerHero
            key={e.id}
            e={e}
            snap={snaps[e.id]}
            mode={mode}
            onOpen={() => open(e)}
            onOpenLife={onOpenLife}
            onChanged={load}
          />
        ) : (
          <OrganizerHero key={e.id} e={e} onOpen={() => open(e)} />
        ),
      )}
      {invites.length > 0 && (
        <>
          <div className="bg-t1-surface px-4 py-2 t1-label">Invitations</div>
          {invites.map((i) => (
            <InviteRow key={i.event_id} invite={i} onJoined={onOpenPlayer} onChanged={load} />
          ))}
        </>
      )}
      {!desktop && <JoinByCode />}
      {!desktop && onNearby && <Row title="Nearby" detail="Open events within 150 m" onClick={onNearby} />}
      {upcoming.length > 0 && (
        <>
          <div className="bg-t1-surface px-4 py-2 t1-label">Upcoming</div>
          {upcoming.map((e) => (
            <EventLine key={e.id} e={e} onOpen={() => open(e)} />
          ))}
        </>
      )}
      {(data?.waitlist ?? []).length > 0 && (
        <>
          <div className="bg-t1-surface px-4 py-2 t1-label">Waitlist</div>
          {(data?.waitlist ?? []).map((w) => (
            <a key={w.event_id} href={`/s/${w.event_id}`} className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-4 flex flex-col gap-1">
              <span className="text-[14px] truncate">{w.name}</span>
              <span className="t1-label truncate">
                {[`Number ${w.position ?? 1} on the waitlist`, when(w.starts_at), w.venue_name].filter(Boolean).join(" · ")}
              </span>
            </a>
          ))}
        </>
      )}
      {followed.length > 0 && (
        <>
          <div className="bg-t1-surface px-4 py-2 t1-label">Following</div>
          {followed.map((f) => (
            <a key={f.event_id} href={`/s/${f.event_id}`} className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-4 flex flex-col gap-1">
              <span className="text-[14px] truncate">{f.name}</span>
              <span className="t1-label truncate">{followedDetail(f)}</span>
            </a>
          ))}
        </>
      )}
      <Suspense fallback={null}><FindEventsSection onCreate={() => setCreating(true)} /></Suspense>
      {past.length > 0 && (
        <>
          <button onClick={() => setShowPast((v) => !v)} className="bg-t1-surface px-4 py-2 t1-label text-left">
            {showPast ? "Past · hide" : `Past · ${past.length}`}
          </button>
          {showPast && past.map((e) => <EventLine key={e.id} e={e} onOpen={() => open(e)} />)}
        </>
      )}
    </>
  );

  return (
    <Screen>
      <TabNav />
      <Bar
        title="Events"
        subtitle={live.length ? `${live.length} live` : undefined}
        right={
          <div className="flex items-center gap-5 shrink-0">
            {/* Find (events, leagues, boards): the sidebar has it on a desktop. */}
            <Link to={demoPath("/find")} aria-label="Find" title="Find"
                  className="lg:hidden w-[50px] h-[50px] -my-3 -mx-4 flex items-center justify-center hover:text-t1-accent">
              <Icon d={BAR_ICON.search} />
            </Link>
            <button onClick={() => onOpenLife()} className="t1-label">
              Life
            </button>
            <button onClick={() => setCreating(true)} className="t1-label">
              + New
            </button>
          </div>
        }
      />
      {error && <Notice tone="error">{error}</Notice>}
      {error && empty && <GhostAction label="Try again" onClick={() => void load()} />}
      {stale && <Notice tone="info">{stale}</Notice>}
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {data === null && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {empty && <EmptyEvents onCreate={() => setCreating(true)} onNearby={onNearby} />}
        {empty && <Suspense fallback={null}><FindEventsSection /></Suspense>}
        {!empty && data && desktop && (
          // Desktop: your events on the left; joining, creating and the tracker on the right.
          <Columns aside={<HomeActions onCreate={() => setCreating(true)} onOpenLife={() => onOpenLife()} onNearby={onNearby} />}>
            {lists}
          </Columns>
        )}
        {!empty && data && !desktop && lists}
      </div>
    </Screen>
  );
}

/** Desktop Events home: the right column. */
function HomeActions({ onCreate, onOpenLife, onNearby }: { onCreate: () => void; onOpenLife: () => void; onNearby?: () => void }) {
  return (
    <>
      <div className="bg-t1-surface px-4 pt-4 pb-2 t1-label">Join with an event code</div>
      <JoinByCode />
      <BigAction label="Create an event" tone="accent" onClick={onCreate} />
      <div className="flex gap-px">
        <GhostAction label="Life tracker" onClick={onOpenLife} />
        {onNearby && <GhostAction label="Nearby" onClick={onNearby} />}
      </div>
    </>
  );
}

/** A round you're playing: clock, table, opponent and ranks, and one-tap reporting. */
function PlayerHero({
  e,
  snap,
  mode,
  onOpen,
  onOpenLife,
  onChanged,
}: {
  e: HomeEvent;
  snap?: LiveSnapshot;
  mode: TrackerMode;
  onOpen: () => void;
  onOpenLife: (matchId: string) => void;
  onChanged: () => void;
}) {
  const [sending, setSending] = useState(false);
  const s = snap?.state;
  const playing = s?.phase === "playing";
  const canReport = playing && s?.canReport && s?.status === "pending";
  const needsAnswer = playing && s?.status === "reported_them";
  const canTrack = playing && !!s?.matchId && s?.mySide != null && !!s?.oppName;

  async function report(my: number, their: number) {
    if (!s?.matchId || s.mySide == null) return;
    setSending(true);
    try {
      await reportFromHome(s.matchId, s.mySide, my, their, s.matchVersion);
    } finally {
      setSending(false);
      onChanged();
    }
  }

  async function respond(accept: boolean) {
    if (!s?.matchId) return;
    await respondToResult(s.matchId, accept).catch(() => {});
    onChanged();
  }

  return (
    <div className="flex flex-col gap-px">
      <button onClick={onOpen} className="bg-t1-surface px-4 py-2.5 flex justify-between text-left">
        <span className="t1-label text-t1-accent!">
          Playing · Round {e.round?.number ?? e.current_round} of {e.number_of_rounds}
        </span>
        <span className="t1-label text-t1-text!">Open ›</span>
      </button>
      <button onClick={onOpen} className="bg-t1-bg py-4 flex flex-col items-center gap-1">
        <span className="text-[15px] truncate max-w-full px-4">{e.name}</span>
        <span className="t1-label">{formatLabelOf(e)}</span>
        {e.show_clock === false ? (
          <span className="t1-label text-t1-text!">Round {e.round?.number ?? e.current_round} of {e.number_of_rounds}</span>
        ) : (
          <Countdown endsAt={s?.endsAt ?? e.round?.ends_at} paused={s?.pausedRemaining ?? e.round?.remaining_seconds} />
        )}
      </button>
      {s && playing ? (
        <>
          <div className="bg-t1-surface px-4 py-3 flex gap-3">
            <Stat label="Table" value={String(s.table ?? "–")} accent />
            <Stat label="You" value={`${s.myRank ? `#${s.myRank}` : "#–"} · ${s.myRecord}`} />
            <Stat label={s.oppRank ? `#${s.oppRank}` : "#–"} value={s.oppName ?? "Opponent"} end />
          </div>
          {canTrack && mode === "tracker" && (
            <BigAction label="Open life tracker" tone="accent" onClick={() => onOpenLife(s.matchId!)} />
          )}
          {canReport && (
            <div className="flex gap-px">
              {[[2, 0], [2, 1], [1, 1], [1, 2], [0, 2]].map(([my, their]) => (
                <button
                  key={`${my}-${their}`}
                  disabled={sending}
                  onClick={() => report(my, their)}
                  className={`flex-1 hover:bg-t1-accent hover:text-t1-ink text-[14px] tabular-nums disabled:opacity-40 ${
                    mode === "tracker" ? "bg-t1-surface py-2.5 text-t1-muted" : "bg-t1-surface-hover py-3.5"
                  }`}
                >
                  {my}-{their}
                </button>
              ))}
            </div>
          )}
          {canTrack && mode !== "tracker" && (
            <div className="flex gap-px">
              <GhostAction label="Open life tracker" onClick={() => onOpenLife(s.matchId!)} />
            </div>
          )}
          {needsAnswer && (
            <div className="flex gap-px">
              <GhostAction label="Dispute" onClick={() => respond(false)} />
              <button onClick={() => respond(true)} className="flex-1 bg-t1-accent text-t1-ink px-4 py-3 text-[11px] uppercase tracking-[1px]">
                Confirm
              </button>
            </div>
          )}
        </>
      ) : (
        <Notice tone="info">Open the event for your table and opponent.</Notice>
      )}
    </div>
  );
}

/** A round you're running: clock and how many results are in. */
function OrganizerHero({ e, onOpen }: { e: HomeEvent; onOpen: () => void }) {
  const r = e.round;
  return (
    <button onClick={onOpen} className="flex flex-col gap-px text-left">
      <div className="bg-t1-surface px-4 py-2.5 flex justify-between w-full">
        <span className="t1-label text-t1-accent!">
          {r ? `Organizing · Round ${r.number} of ${e.number_of_rounds}` : "Organizing · Seating"}
        </span>
        <span className="t1-label text-t1-text!">Open ›</span>
      </div>
      <div className="bg-t1-bg py-3.5 flex flex-col items-center gap-1 w-full">
        <span className="text-[15px] truncate max-w-full px-4">{e.name}</span>
        <span className="t1-label">{formatLabelOf(e)}</span>
        {r && e.show_clock !== false ? (
          <Countdown endsAt={r.ends_at} paused={r.remaining_seconds} size={44} />
        ) : (
          <span className="text-[28px]">{e.players} players</span>
        )}
      </div>
      {r ? (
        <div className={`px-4 py-3 flex gap-3 w-full ${r.disputed > 0 ? "bg-t1-danger/15" : "bg-t1-surface"}`}>
          <Stat label="Results in" value={`${r.results_in} of ${r.matches}`} accent={r.results_in === r.matches} />
          <Stat label="Disputed" value={String(r.disputed)} />
          <Stat label="Players" value={String(e.players)} end />
        </div>
      ) : (
        <div className="w-full">
          <Notice tone="info">Pair round 1 when everyone is seated.</Notice>
        </div>
      )}
    </button>
  );
}

function EventLine({ e, onOpen }: { e: HomeEvent; onOpen: () => void }) {
  const parts = [e.organizing ? "Organizing" : "Playing", formatLabelOf(e)];
  if (e.bucket === "upcoming") {
    const at = when(e.starts_at);
    if (at) parts.push(at);
    parts.push(e.capacity ? `${e.players}/${e.capacity} signed up` : `${e.players} signed up`);
    if (e.playing && e.decklists && e.decklists !== "off" && !e.my_decklist) parts.push("Add your decklist");
  } else if (e.status === "cancelled") {
    if (e.cancel_reason) parts.push(e.cancel_reason);
  } else {
    parts.push(`${e.number_of_rounds} rounds · ${e.players} players`);
  }
  return (
    <button onClick={onOpen} className="bg-t1-surface hover:bg-t1-surface-hover px-4 py-4 text-left flex items-center gap-3">
      <span className="flex-1 min-w-0 flex flex-col gap-1">
        <span className="text-[14px] truncate">{e.name}</span>
        <span className="t1-label truncate">{parts.join(" · ")}</span>
      </span>
      {e.status === "cancelled" && <span className="t1-label text-t1-danger!">Cancelled</span>}
    </button>
  );
}

function InviteRow({ invite, onJoined, onChanged }: { invite: HomeInvite; onJoined: (id: string) => void; onChanged: () => void }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  async function answer(accept: boolean) {
    setBusy(true);
    setError(null);
    try {
      await respondToInvite(invite.event_id, accept);
      if (accept) onJoined(invite.event_id);
      else onChanged();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }
  const detail = [
    invite.source === "nearby_alert" ? "Starting near you" : `From ${invite.invited_by ?? "an organizer"}`,
    formatLabelOf(invite),
    shortWhen(invite.starts_at),
    invite.venue_name,
  ]
    .filter(Boolean)
    .join(" · ");
  return (
    <>
      <div className="bg-t1-surface px-4 py-3 flex items-center gap-3">
        <div className="flex-1 min-w-0">
          <p className="text-[14px] truncate">{invite.name}</p>
          <p className="t1-label truncate">{detail}</p>
          <p className="text-[11px] leading-[15px] text-t1-muted mt-1">{JOIN_NOTICE}</p>
        </div>
        <button disabled={busy} onClick={() => answer(false)} className="px-3 py-2 text-[11px] uppercase tracking-[1px] bg-t1-bg">
          Decline
        </button>
        <button disabled={busy} onClick={() => answer(true)} className="px-3 py-2 text-[11px] uppercase tracking-[1px] bg-t1-accent text-t1-ink">
          Join
        </button>
      </div>
      {error && <Notice tone="error">{error}</Notice>}
    </>
  );
}

/** No events and no invitations: the ways in become the screen. */
function EmptyEvents({ onCreate, onNearby }: { onCreate: () => void; onNearby?: () => void }) {
  return (
    <>
      <div className="bg-t1-surface px-6 py-10 flex flex-col items-center gap-2 text-center">
        <p className="text-[20px]">No events yet</p>
        <p className="text-[12px] text-t1-muted">
          Scan an organizer's QR code with your phone's camera, enter an event code, or run your own.
        </p>
      </div>
      <JoinByCode />
      {onNearby && <Row title="Nearby" detail="Open events within 150 m" onClick={onNearby} />}
      <BigAction label="Create an event" tone="accent" onClick={onCreate} />
    </>
  );
}



/**
 * One scrolling form: type → format → product (limited) → teams → rounds → round timer → players.
 * The server names the event from these choices ("Draft · Duskmourn · Fri 17 Oct"); rounds are always 50 minutes.
 */
export function NewEvent({
  onCancel,
  onCreated,
}: {
  onCancel: () => void;
  onCreated: (eventId: string) => void;
}) {
  const [format, setFormat] = useState<FormatName>("draft");
  const [formatOther, setFormatOther] = useState("");
  const [product, setProduct] = useState<"set" | "cube">("set");
  const [set, setSet] = useState<DraftableSet | null>(null);
  const [setNameText, setSetNameText] = useState("");
  const [cubeName, setCubeName] = useState("");
  const [cubeUrl, setCubeUrl] = useState("");
  const [teamSize, setTeamSize] = useState<3 | 4>(3);
  const [rounds, setRounds] = useState(3);
  const [showClock, setShowClock] = useState(true);
  const [includeMe, setIncludeMe] = useState(true);
  const [myName, setMyName] = useState<string | null>(null);
  const [guests, setGuests] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  // Roto only: prefilled from the player count (round robin for 2–8, Swiss for 9+) until changed by hand.
  const [pairing, setPairing] = useState<"swiss" | "round_robin" | null>(null);
  const [name, setName] = useState("");
  const [schedule, setSchedule] = useState<ScheduleValue>({ startsAt: null, venueName: "", capacity: null });
  /** Who can find it (contract/public-events-leagues-2026-11-13.md § 1): Public, Friends or Private (the default:
   *  QR, code, link or invitation). Until the server lists events, the older Nearby + QR | QR only shows instead. */
  const [find, setFind] = useState<FindPick>("private");
  const [listings, setListings] = useState(true);
  useEffect(() => {
    let live = true;
    void listingsLive().then((on) => live && setListings(on));
    return () => { live = false; };
  }, []);
  const [description, setDescription] = useState("");
  const [address, setAddress] = useState("");
  const [describing, setDescribing] = useState(false);
  /** The older picker: Nearby + QR (players within 150 m, and alerts) or QR only. */
  const [nearby, setNearby] = useState(true);
  const [autoRounds, setAutoRounds] = useState(true);
  const [topCut, setTopCut] = useState<0 | 8>(0);
  const [decklists, setDecklists] = useState<DecklistMode>("off");
  /** Drafts: null = automatic pods (up to 8 each); how rounds 2+ pair (contract/draft-pods-2026-11-09.md). */
  const [podsPick, setPodsPick] = useState<number | null>(null);
  const [podPairing, setPodPairing] = useState<PodPairing>("pod");
  const roto = format === "roto";
  const hasPods = format === "draft";
  const playerCount = guests.length + (includeMe ? 1 : 0);
  const shownPairing = pairing ?? defaultPairing(playerCount);

  useEffect(() => {
    let live = true;
    myDisplayName().then((n) => live && setMyName(n));
    return () => {
      live = false;
    };
  }, []);

  const limited = typeOfFormat(format) === "limited";
  const team = isTeamFormat(format);
  const cubeProduct = product === "cube" || roto;
  const productName = !limited ? null : cubeProduct ? cubeName.trim() || null : set?.name ?? (setNameText.trim() || null);
  const preview = eventNamePreview(format, { other: formatOther, product: productName },
                                   schedule.startsAt ? new Date(schedule.startsAt) : new Date());
  const typedName = name.trim().replace(/\s+/g, " ");
  // Swiss events of players: automatic rounds and the top cut apply.
  const swiss = !team && !(roto && shownPairing === "round_robin");

  const cubeUrlBad = limited && cubeProduct && !!cubeUrlProblem(cubeUrl);
  const problem =
    format === "other_constructed" && !formatOther.trim()
      ? "Name the format"
      : limited && cubeProduct && !cubeName.trim()
        ? "Name the cube"
        : cubeUrlBad
          ? "Paste a Cube Cobra link"
          : null;

  async function submit() {
    if (problem) return;
    setBusy(true);
    setError(null);
    try {
      const { eventId } = await createEventV2({
        formatName: format,
        rounds,
        showClock,
        setCode: limited && !cubeProduct ? set?.code ?? null : null,
        setName: limited && !cubeProduct ? set?.name ?? (setNameText.trim() || null) : null,
        cubeName: limited && cubeProduct ? cubeName.trim().slice(0, 80) : null,
        cubeUrl: limited && cubeProduct && cubeUrl.trim() ? cubeUrl.trim() : null,
        teamSize: team ? teamSize : null,
        formatOther: format === "other_constructed" ? formatOther.trim().slice(0, 40) : null,
        playerNames: guests,
        includeMe,
        pairing: roto ? shownPairing : null,
        name: typedName || null,
        startsAt: schedule.startsAt,
        venueName: schedule.venueName,
        capacity: schedule.capacity,
        topCut: swiss ? topCut : 0,
        autoRounds: swiss && autoRounds,
        decklists: limited ? "off" : decklists,
      });
      // Roto: the pool comes from a Library cube. Use the one with this name, or import the Cube Cobra link.
      if (roto) void linkRotoCube(eventId, cubeName, cubeUrl);
      // Drafts: the pods, when not the defaults (automatic, inside pods). Setup → Seating can change them.
      if (hasPods && (podsPick != null || podPairing !== "pod")) await setEventPods(eventId, podsPick, podPairing).catch(() => {});
      // Pin it where the organizer stands. For nearby events this also alerts opted-in players around. A scheduled
      // event is usually made away from the venue: no pin then (Details can set it there).
      const listed = listings && find !== "private";
      const fix = schedule.startsAt ? null : await currentFix(6000);
      if (fix && !listed) {
        await setEventLocation(eventId, fix, schedule.venueName.trim() || null, !listings && nearby ? "nearby" : "link_only").catch(() => {});
      }
      // Listed, or with a description or address: the listing, with the place when the organizer shared it.
      const about = { description: description.trim() || null, venue_address: address.trim() || null };
      if (listings && (listed || about.description || about.venue_address)) {
        await eventListingSet(eventId, { ...(listed ? { find } : {}), ...about, ...(fix && listed ? { lat: fix.lat, lng: fix.lng } : {}) }).catch(() => {});
      }
      onCreated(eventId);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <Screen>
      <Bar
        title="New event"
        subtitle={typedName || preview}
        right={
          <button onClick={onCancel} className="t1-label shrink-0">
            Cancel
          </button>
        }
      />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        <Field label="Event name (optional)" value={name} onChange={(v) => setName(v.slice(0, 80))} placeholder={preview} />
        <FormatPicker format={format} onFormat={setFormat} formatOther={formatOther} onFormatOther={setFormatOther} />
        {limited && (
          <ProductPicker
            product={product}
            onProduct={setProduct}
            set={set}
            onSet={setSet}
            setNameText={setNameText}
            onSetNameText={setSetNameText}
            cubeName={cubeName}
            onCubeName={setCubeName}
            cubeUrl={cubeUrl}
            onCubeUrl={setCubeUrl}
            cubeOnly={roto}
          />
        )}
        {roto && (
          <Notice tone="info">
            Roto: every card face up, players take turns picking any card, snake order. The pool is one of your Library
            cubes; a Cube Cobra link is imported into your Library. You can change it in Setup → Details.
          </Notice>
        )}

        {team && (
          <Segmented
            label="Players per team"
            value={teamSize}
            onChange={setTeamSize}
            options={[
              { value: 3, label: "3" },
              { value: 4, label: "4" },
            ]}
          />
        )}

        {hasPods && (
          <DraftPodFields pods={podsPick} pairing={podPairing} players={playerCount}
                          onChange={(n, p) => { setPodsPick(n); setPodPairing(p); }} />
        )}

        <ScheduleFields value={schedule} onChange={setSchedule} />
        <Section title="Rounds" />
        {!(roto && shownPairing === "round_robin") && (
          <CutAndRoundsFields autoRounds={autoRounds} onAutoRounds={setAutoRounds} rounds={rounds} onRounds={setRounds}
                              topCut={topCut} onTopCut={setTopCut} players={playerCount} swiss={swiss}
                              autoDetail={hasPods ? draftAutoLabel(playerCount, podsPick, podPairing) : undefined} />
        )}
        {roto && <RotoPairingFields pairing={shownPairing} onPairing={setPairing} players={playerCount} />}
        <RoundTimerSwitch on={showClock} onChange={setShowClock} />
        {!limited && <DecklistsFields mode={decklists} onMode={setDecklists} />}
        <PlayersEditor includeMe={includeMe} onIncludeMe={setIncludeMe} myName={myName} guests={guests} onGuests={setGuests} />
        {listings ? (
          <>
            <Row title="Description" detail={description.trim() ? counter(description.length, DESCRIPTION_MAX) : "None"}
                 value={<Icon d={BAR_ICON.arrow} />} onClick={() => setDescribing(true)} />
            <Field label="Address" value={address} onChange={(v) => setAddress(v.slice(0, ADDRESS_MAX))} placeholder="Street and city" />
            <Segmented label="Who can find it" value={find} onChange={setFind} options={FIND_PICKS} />
            <Notice tone="info">
              {find === "public" ? "Listed for everyone in Find events. Results in public events are public."
                : find === "friends" ? "Listed for your friends. The link still opens for whoever has it."
                : "Only people with the code, link or QR code can join."}
            </Notice>
          </>
        ) : (
          <>
            <Segmented label="Who can find it" value={nearby ? "nearby" : "qr"} onChange={(v) => setNearby(v === "nearby")}
                       options={[{ value: "nearby", label: "Nearby + QR" }, { value: "qr", label: "QR only" }]} />
            <Notice tone="info">
              {schedule.startsAt ? "Scheduled events are pinned from Details at the venue."
                : nearby ? "Players within 150 m can find and join it, and players nearby who turned on alerts get a Join / Decline notification. Your browser asks for your location once."
                : "Only people with the code, link or QR code can join."}
            </Notice>
          </>
        )}
        {error && <Notice tone="error">{error}</Notice>}
      </div>
      <BigAction label="Create event" tone="accent" busy={busy} disabled={!!problem} onClick={submit} />
      {describing && (
        <TextPanel title="Description" value={description} max={DESCRIPTION_MAX} placeholder="What players should know"
                   onSave={(text) => setDescription(text)} onClose={() => setDescribing(false)} />
      )}
    </Screen>
  );
}
