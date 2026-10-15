import { useCallback, useEffect, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabaseClient";
import {
  createEventV2,
  fetchEventsHome,
  formatLabelOf,
  fetchLiveSnapshots,
  reportFromHome,
  respondToInvite,
  respondToResult,
  errorMessage,
} from "../lib/api";
import type { DraftableSet, FormatName, HomeData, HomeEvent, HomeInvite, LiveSnapshot, TrackerMode } from "../lib/types";
import { SignInButtons } from "../components/SignInButtons";
import { FormatPicker, ProductPicker, cubeUrlProblem } from "../components/EventFormFields";
import { claimAutoOpen, useTrackerMode } from "../lib/settings";
import { defaultEventName, isTeamFormat, typeOfFormat } from "../lib/formats";
import {
  Bar,
  BigAction,
  Countdown,
  Field,
  GhostAction,
  Notice,
  Screen,
  Segmented,
  Stat,
  Stepper,
  T1Logo,
  TopNav,
  shortWhen,
} from "../components/kit";

/**
 * The Events tab. What's happening now comes first and biggest; joining and creating are secondary
 * until there's nothing to show.
 */
export function Home({
  onOpenEvent,
  onOpenPlayer,
  onAddPlayers,
  onOpenLife,
}: {
  onOpenEvent: (eventId: string) => void;
  onOpenPlayer: (eventId: string) => void;
  onAddPlayers: (eventId: string) => void;
  /** No match id: the local tracker. */
  onOpenLife: (matchId?: string) => void;
}) {
  const [session, setSession] = useState<Session | null>(null);
  const [ready, setReady] = useState(false);
  const [data, setData] = useState<HomeData | null>(null);
  const [snaps, setSnaps] = useState<Record<string, LiveSnapshot>>({});
  const [showPast, setShowPast] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const { mode } = useTrackerMode();

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setReady(true);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => sub.subscription.unsubscribe();
  }, []);

  const load = useCallback(async () => {
    try {
      setData(await fetchEventsHome());
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
      setData((d) => d ?? { events: [], invites: [] });
    }
    const live = await fetchLiveSnapshots();
    setSnaps(Object.fromEntries(live.map((s) => [s.eventId, s])));
  }, []);

  useEffect(() => {
    if (session) load();
  }, [session, load]);

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

  if (!session) return <AuthScreen />;

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
  const empty = data !== null && data.events.length === 0 && invites.length === 0;

  return (
    <Screen>
      <TopNav />
      <Bar
        title="Events"
        subtitle={live.length ? `${live.length} live` : undefined}
        right={
          <div className="flex gap-5 shrink-0">
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
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {data === null && <div className="bg-t1-surface px-4 py-4 t1-label">Loading…</div>}
        {empty && <EmptyEvents onCreate={() => setCreating(true)} />}
        {!empty && data && (
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
            <JoinByCode />
            {upcoming.length > 0 && (
              <>
                <div className="bg-t1-surface px-4 py-2 t1-label">Upcoming</div>
                {upcoming.map((e) => (
                  <EventLine key={e.id} e={e} onOpen={() => open(e)} />
                ))}
              </>
            )}
            {past.length > 0 && (
              <>
                <button onClick={() => setShowPast((v) => !v)} className="bg-t1-surface px-4 py-2 t1-label text-left">
                  {showPast ? "Past · hide" : `Past · ${past.length}`}
                </button>
                {showPast && past.map((e) => <EventLine key={e.id} e={e} onOpen={() => open(e)} />)}
              </>
            )}
          </>
        )}
      </div>
    </Screen>
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
        <Countdown endsAt={s?.endsAt ?? e.round?.ends_at} paused={s?.pausedRemaining ?? e.round?.remaining_seconds} />
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
        {r ? <Countdown endsAt={r.ends_at} paused={r.remaining_seconds} size={44} /> : <span className="text-[28px]">{e.players} players</span>}
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
    const when = shortWhen(e.starts_at);
    if (when) parts.push(when);
    parts.push(`${e.players} signed up`);
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
function EmptyEvents({ onCreate }: { onCreate: () => void }) {
  return (
    <>
      <div className="bg-t1-surface px-6 py-10 flex flex-col items-center gap-2 text-center">
        <p className="text-[20px]">No events yet</p>
        <p className="text-[12px] text-t1-muted">
          Scan an organizer's QR code with your phone's camera, enter an event code, or run your own.
        </p>
      </div>
      <JoinByCode />
      <BigAction label="Create an event" tone="accent" onClick={onCreate} />
    </>
  );
}

function JoinByCode() {
  const [code, setCode] = useState("");
  return (
    <div className="flex gap-px">
      <input
        value={code}
        onChange={(e) => setCode(e.target.value.toUpperCase())}
        placeholder="EVENT CODE"
        maxLength={6}
        className="flex-1 min-w-0 bg-t1-surface px-4 py-4 outline-0 border-0 text-[16px] tracking-[4px] placeholder:text-t1-muted/60 uppercase"
      />
      <button
        disabled={code.trim().length < 4}
        onClick={() => (window.location.href = `/join/${code.trim()}`)}
        className="bg-t1-text text-t1-bg px-6 text-[11px] uppercase tracking-[1px] disabled:bg-t1-disabled disabled:text-t1-ink"
      >
        Join
      </button>
    </div>
  );
}

/** The mark, full-bleed, over the sign-in actions. Matches the "Sign in" frames in Figma. */
function AuthScreen() {
  return (
    <Screen>
      <div className="flex-1 bg-t1-surface flex items-center justify-center pt-10 overflow-hidden">
        <T1Logo className="w-full max-w-[720px] h-auto" />
      </div>
      <SignInButtons />
    </Screen>
  );
}

/**
 * One scrolling form: type → format → product (limited) → teams → rounds → round length → name → players.
 * The name follows the format until the organizer types their own.
 */
function NewEvent({
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
  const [minutes, setMinutes] = useState("50");
  const [name, setName] = useState<string | null>(null); // null = follow the format
  const [namesText, setNamesText] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const limited = typeOfFormat(format) === "limited";
  const team = isTeamFormat(format);
  const productName = !limited ? null : product === "cube" ? cubeName.trim() || null : set?.name ?? (setNameText.trim() || null);
  const suggested = defaultEventName(format, { other: formatOther, product: productName });
  const eventName = name ?? suggested;

  const playerNames = namesText
    .split("\n")
    .map((n) => n.trim())
    .filter(Boolean);

  const cubeUrlBad = limited && product === "cube" && !!cubeUrlProblem(cubeUrl);
  const problem = !eventName.trim()
    ? "Name the event"
    : format === "other_constructed" && !formatOther.trim()
      ? "Name the format"
      : limited && product === "cube" && !cubeName.trim()
        ? "Name the cube"
        : cubeUrlBad
          ? "The CubeCobra link must start with https://"
          : null;

  async function submit() {
    if (problem) return;
    setBusy(true);
    setError(null);
    try {
      const { eventId } = await createEventV2({
        name: eventName.trim().slice(0, 80),
        formatName: format,
        rounds,
        roundSeconds: Math.max(1, Number(minutes) || 50) * 60,
        setCode: limited && product === "set" ? set?.code ?? null : null,
        setName: limited && product === "set" ? set?.name ?? (setNameText.trim() || null) : null,
        cubeName: limited && product === "cube" ? cubeName.trim().slice(0, 80) : null,
        cubeUrl: limited && product === "cube" && cubeUrl.trim() ? cubeUrl.trim() : null,
        teamSize: team ? teamSize : null,
        formatOther: format === "other_constructed" ? formatOther.trim().slice(0, 40) : null,
        playerNames,
      });
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
        subtitle={suggested}
        right={
          <button onClick={onCancel} className="t1-label shrink-0">
            Cancel
          </button>
        }
      />
      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
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
          />
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

        <Stepper label="Rounds" value={rounds} onChange={setRounds} min={1} max={15} />
        <Field label="Round length (minutes)" value={minutes} onChange={setMinutes} type="number" />
        <Field label="Event name" value={eventName} onChange={(v) => setName(v.slice(0, 80))} />

        <label className="bg-t1-surface px-4 py-3 flex flex-col gap-1">
          <span className="t1-label">Players — one per line (optional, they can also join by code)</span>
          <textarea
            value={namesText}
            onChange={(e) => setNamesText(e.target.value)}
            rows={6}
            placeholder={"Alex\nBrit\nCasey\n…"}
            className="bg-transparent border-0 outline-0 text-[14px] text-t1-text placeholder:text-t1-muted/60 w-full resize-none"
          />
        </label>
        <Notice tone="info">
          {playerNames.length} player{playerNames.length === 1 ? "" : "s"} · {rounds} round{rounds === 1 ? "" : "s"}
          {team ? ` · teams of ${teamSize}` : ""}
        </Notice>
        {error && <Notice tone="error">{error}</Notice>}
      </div>
      <BigAction label="Create event" tone="accent" busy={busy} disabled={!!problem} onClick={submit} />
    </Screen>
  );
}
