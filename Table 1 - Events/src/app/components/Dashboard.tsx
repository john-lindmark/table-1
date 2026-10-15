import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import type { EventState, EventStatus, MatchupMethod, SyncStatus } from "../lib/types";
import { allResultsEntered, hasInvalidPairing } from "../lib/scoring";
import { api, type EventBundle } from "../lib/api";
import { getSupabase } from "../lib/supabaseClient";
import { computeRemaining } from "./Timer";
import { FormatGrid } from "./FormatGrid";
import { ScoreBar } from "./ScoreBar";
import { TeamTotals } from "./TeamTotals";
import { Timer } from "./Timer";
import { RecordButton } from "./RecordButton";
import { StatusBar } from "./StatusBar";
import { ManagementDrawer } from "./ManagementDrawer";
import { CompletedDashboard } from "./CompletedDashboard";

const MONO = "var(--font-sf-mono)";

function cycle(n: number): number {
  return (n + 1) % 3;
}

// Map the server bundle into the frontend EventState shape.
function toEventState(b: EventBundle): EventState {
  return {
    id: b.event.id,
    name: b.event.name,
    status: b.event.status as EventStatus,
    matchupMethod: b.event.matchupMethod as MatchupMethod,
    numberOfRounds: b.event.numberOfRounds,
    currentRoundNumber: b.event.currentRoundNumber,
    drawsAllowed: b.event.drawsAllowed,
    teams: b.teams,
    formats: b.formats,
    players: b.players,
    currentPairings: b.currentPairings,
    recordedRounds: b.recordedRounds.map((r) => ({
      roundNumber: r.roundNumber,
      pairings: r.pairings,
      recordedAt: r.recordedAt,
    })),
    timer: {
      durationSeconds: b.timer.durationSeconds,
      remainingSecondsAtChange: b.timer.remainingSecondsAtChange,
      status: b.timer.status,
      lastStartedAt: b.timer.lastStartedAt,
    },
    role: b.role,
  };
}

interface DashboardProps {
  eventId: string;
  dark: boolean;
  onToggleDark: () => void;
  onSignOut: () => void;
  onNavigateEvent: (eventId: string) => void;
  onBack?: () => void;
}

export function Dashboard({
  eventId,
  dark,
  onToggleDark,
  onSignOut,
  onNavigateEvent,
  onBack,
}: DashboardProps) {
  const [event, setEvent] = useState<EventState | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [offline, setOffline] = useState(false);
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [recording, setRecording] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [sync, setSync] = useState<SyncStatus>("saved");

  // Keep the latest event snapshot for optimistic-update reverts without adding
  // it to callback dependency lists.
  const eventRef = useRef<EventState | null>(null);
  eventRef.current = event;

  // Sequence number to ignore stale server responses when mutations overlap.
  const mutationSeq = useRef(0);

  const refetch = useCallback(async () => {
    try {
      const bundle = await api.getEvent(eventId);
      setEvent(toEventState(bundle));
      setLoadError(null);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`Failed to load event ${eventId}:`, msg);
      if (!eventRef.current) setLoadError(msg);
      setSync("error");
    }
  }, [eventId]);

  // Initial load.
  useEffect(() => {
    setEvent(null);
    setLoadError(null);
    refetch();
  }, [refetch]);

  // Realtime sync on the event's KV row, with a 20s polling fallback.
  useEffect(() => {
    const supabase = getSupabase();
    const channel = supabase
      .channel(`event-${eventId}`)
      .on(
        "postgres_changes",
        {
          event: "*",
          schema: "public",
          table: "kv_store_a539856f",
          filter: `key=eq.event:${eventId}`,
        },
        () => refetch(),
      )
      .subscribe();
    const poll = window.setInterval(() => {
      if (!offline) refetch();
    }, 20000);
    return () => {
      supabase.removeChannel(channel);
      window.clearInterval(poll);
    };
  }, [eventId, offline, refetch]);

  const canEdit = !!event && (event.role === "owner" || event.role === "organizer");
  const allEntered = !!event && allResultsEntered(event);
  const invalid = !!event && hasInvalidPairing(event);
  const isFinalRound = !!event && event.currentRoundNumber >= event.numberOfRounds;
  const effectiveSync: SyncStatus = offline ? "offline" : sync;

  // Optimistic mutation: apply locally, call the server, reconcile with the
  // returned bundle, and revert to the prior snapshot on failure.
  const withSave = useCallback(
    async (optimistic: (prev: EventState) => EventState, call: () => Promise<EventBundle>) => {
      if (offline) return;
      const snapshot = eventRef.current;
      if (!snapshot) return;
      // Update ref immediately so rapid clicks read the latest optimistic state
      // before React has had a chance to re-render.
      const optimisticState = optimistic(snapshot);
      eventRef.current = optimisticState;
      setEvent(optimisticState);
      setSync("saving");
      const seq = ++mutationSeq.current;
      try {
        const bundle = await call();
        // Only apply the server response if no newer mutation has since fired,
        // to avoid an earlier response overwriting a later optimistic update.
        if (seq === mutationSeq.current) {
          setEvent(toEventState(bundle));
          setSync("saved");
        }
      } catch (e) {
        if (seq === mutationSeq.current) {
          const msg = e instanceof Error ? e.message : String(e);
          console.error(`Save failed for event ${eventId}:`, msg);
          setEvent(snapshot);
          eventRef.current = snapshot;
          setSync("error");
        }
      }
    },
    [eventId, offline],
  );

  const cycleWins = useCallback(
    (pairingId: string, side: "a" | "b") => {
      if (!canEdit) return;
      const cur = eventRef.current?.currentPairings.find((p) => p.id === pairingId);
      if (!cur) return;
      const a = side === "a" ? cycle(cur.teamAGameWins ?? 0) : cur.teamAGameWins ?? 0;
      const b = side === "b" ? cycle(cur.teamBGameWins ?? 0) : cur.teamBGameWins ?? 0;
      // Capture the displayed clock at the moment of the click, not at API arrival.
      const clockSecondsRemaining = computeRemaining(eventRef.current!.timer, Date.now());
      withSave(
        (prev) => ({
          ...prev,
          currentPairings: prev.currentPairings.map((p) =>
            p.id === pairingId
              ? { ...p, teamAGameWins: a, teamBGameWins: b, tieResolutionTeamId: null }
              : p,
          ),
        }),
        () => api.setResult(eventId, pairingId, a, b, null, clockSecondsRemaining),
      );
    },
    [canEdit, eventId, withSave],
  );


  const toggleTimer = useCallback(() => {
    if (!canEdit || !eventRef.current) return;
    const running = eventRef.current.timer.status === "running";
    const action = running ? "pause" : "resume";
    withSave(
      (prev) => {
        const now = Date.now();
        if (running) {
          return {
            ...prev,
            timer: {
              ...prev.timer,
              status: "paused",
              remainingSecondsAtChange: computeRemaining(prev.timer, now),
              lastStartedAt: null,
            },
          };
        }
        return { ...prev, timer: { ...prev.timer, status: "running", lastStartedAt: now } };
      },
      () => api.timer(eventId, action),
    );
  }, [canEdit, eventId, withSave]);

  const recordAndAdvance = useCallback(async () => {
    if (!eventRef.current) return;
    setRecording(true);
    setSync("saving");
    try {
      const bundle = await api.record(eventId, eventRef.current.currentRoundNumber);
      setEvent(toEventState(bundle));
      setSync("saved");
      setConfirmOpen(false);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      console.error(`Failed to record round for event ${eventId}:`, msg);
      setSync("error");
    } finally {
      setRecording(false);
    }
  }, [eventId]);

  const onRecordClick = useCallback(() => {
    if (!allEntered) return;
    setConfirmOpen(true);
  }, [allEntered]);

  const correct = useCallback(
    (roundNumber: number, pairingId: string, aWins: number, bWins: number, reason: string) => {
      withSave(
        (prev) => ({
          ...prev,
          recordedRounds: prev.recordedRounds.map((r) =>
            r.roundNumber !== roundNumber
              ? r
              : {
                  ...r,
                  pairings: r.pairings.map((p) =>
                    p.id === pairingId
                      ? { ...p, teamAGameWins: aWins, teamBGameWins: bWins, tieResolutionTeamId: null }
                      : p,
                  ),
                },
          ),
        }),
        () => api.correct(eventId, roundNumber, pairingId, aWins, bWins, reason, null),
      );
    },
    [eventId, withSave],
  );

  const rename = useCallback(
    (name: string) => {
      withSave(
        (prev) => ({ ...prev, name }),
        () => api.update(eventId, { name }),
      );
    },
    [eventId, withSave],
  );

  const setTimerMinutes = useCallback(
    (minutes: number) => {
      const secs = Math.max(1, Math.round(minutes * 60));
      withSave(
        (prev) => ({
          ...prev,
          timer: {
            ...prev.timer,
            durationSeconds: secs,
            remainingSecondsAtChange: secs,
            status: "paused",
            lastStartedAt: null,
          },
        }),
        () => api.timer(eventId, "reset", secs),
      );
    },
    [eventId, withSave],
  );

  if (loadError) {
    return (
      <Splash dark={dark}>
        <p className="text-[var(--destructive)] text-[12px] max-w-[320px] text-center leading-[18px]">
          Could not load this event: {loadError}
        </p>
        <button
          onClick={refetch}
          className="text-[#171725] dark:text-white text-[11px] uppercase tracking-[1px] underline"
        >
          Retry
        </button>
      </Splash>
    );
  }

  if (!event) {
    return (
      <Splash dark={dark}>
        <p className="text-[#545461] dark:text-[#c4c4ca] text-[12px] tracking-[2px] uppercase">
          Loading event…
        </p>
      </Splash>
    );
  }

  // ── completed event view ─────────────────────────────────────────────────────
  if (event.status === "completed") {
    return (
      <div className={`${dark ? "dark" : ""} h-screen w-full overflow-hidden`}>
        <div className="h-full w-full bg-white dark:bg-[#171725] flex flex-col">
          <CompletedDashboard
            event={event}
            onOpenSettings={() => setDrawerOpen(true)}
            onBack={onBack ?? onSignOut}
            onSignOut={onSignOut}
          />
        </div>
        {drawerOpen && (
          <ManagementDrawer
            event={event}
            dark={dark}
            offline={offline}
            onToggleDark={onToggleDark}
            onToggleOffline={() => setOffline((o) => !o)}
            onRename={rename}
            onSetTimerMinutes={setTimerMinutes}
            onCorrect={correct}
            onCreated={(id) => {
              setDrawerOpen(false);
              onNavigateEvent(id);
            }}
            onNavigateEvent={(id) => {
              setDrawerOpen(false);
              onNavigateEvent(id);
            }}
            onClose={() => setDrawerOpen(false)}
          />
        )}
      </div>
    );
  }

  // ── live event view ───────────────────────────────────────────────────────────
  const recordLabel = isFinalRound ? "Complete Event" : `Record Round ${event.currentRoundNumber}`;

  return (
    <div className={`${dark ? "dark" : ""} h-screen w-full overflow-hidden`}>
      {/* bg on a child so the dark: variant (which targets descendants) applies */}
      <div className="h-full w-full bg-white dark:bg-[#171725] flex flex-col gap-px overflow-hidden">
        {/* Format grid + Record button — fixed height, not stretched */}
        <div className="shrink-0 flex flex-col gap-px w-full">
          <FormatGrid
            event={event}
            canEdit={canEdit && !offline}
            onCycleWins={cycleWins}
          />
          <RecordButton
            label={isFinalRound ? "Complete Event" : `Record Round ${event.currentRoundNumber}`}
            disabled={!canEdit || offline || event.status === "completed"}
            busy={recording}
            incomplete={!allEntered}
            onClick={onRecordClick}
          />
        </div>

        {/* Score bar — fixed 40px, shrink-0 */}
        <ScoreBar event={event} />

        {/* Team totals — fixed row height, shrink-0 */}
        <TeamTotals event={event} />

        {/* Timer — flex-[1_0_0] inside Timer fills remaining vertical space */}
        <Timer
          timer={event.timer}
          canEdit={canEdit && !offline}
          onToggle={toggleTimer}
          onOpenSettings={() => setDrawerOpen(true)}
        />

        {/* Timer progress bar — flush to bottom */}
        <StatusBar timer={event.timer} />
      </div>

      {drawerOpen && (
        <ManagementDrawer
          event={event}
          dark={dark}
          offline={offline}
          onToggleDark={onToggleDark}
          onToggleOffline={() => setOffline((o) => !o)}
          onRename={rename}
          onSetTimerMinutes={setTimerMinutes}
          onCorrect={correct}
          onCreated={(id) => {
            setDrawerOpen(false);
            onNavigateEvent(id);
          }}
          onNavigateEvent={(id) => {
            setDrawerOpen(false);
            onNavigateEvent(id);
          }}
          onClose={() => setDrawerOpen(false)}
        />
      )}

      {confirmOpen && (
        <div className="fixed inset-0 z-50 flex items-center justify-center" style={{ fontFamily: MONO }}>
          <div className="absolute inset-0 bg-black/60" onClick={() => setConfirmOpen(false)} />
          <div className="relative bg-white dark:bg-[#171725] max-w-[380px] w-[90%] p-[24px] flex flex-col gap-[16px] border border-[var(--border)]">
            <p className="text-[16px] text-[#171725] dark:text-white tracking-[0.5px]">
              {isFinalRound ? "Complete this event?" : `Record Round ${event.currentRoundNumber}?`}
            </p>
            <p className="text-[12px] leading-[18px] text-[#545461] dark:text-[#c4c4ca]">
              This finalizes all match results for this round and advances the event. Results
              can still be corrected afterward with a reason.
            </p>
            {invalid && (
              <p className="text-[12px] text-[var(--destructive)]">
                Resolve all 2–2 scores before recording.
              </p>
            )}
            <div className="flex gap-px">
              <button
                onClick={() => setConfirmOpen(false)}
                className="flex-1 py-[12px] bg-[#f5f5f6] dark:bg-[#282839] text-[#171725] dark:text-white text-[12px] uppercase tracking-[1px]"
              >
                Cancel
              </button>
              <button
                onClick={recordAndAdvance}
                disabled={recording}
                className="flex-1 py-[12px] bg-[#171725] dark:bg-white text-white dark:text-[#171725] text-[12px] uppercase tracking-[1px] disabled:opacity-60"
              >
                {recording ? "Recording…" : "Confirm"}
              </button>
            </div>
          </div>
        </div>
      )}

      <button
        onClick={onSignOut}
        className="fixed bottom-[12px] right-[12px] z-40 text-[10px] uppercase tracking-[1px] text-[#545461] dark:text-[#c4c4ca] bg-white/80 dark:bg-[#171725]/80 px-[10px] py-[6px]"
        style={{ fontFamily: MONO }}
      >
        Sign out
      </button>
    </div>
  );
}

function Splash({ dark, children }: { dark: boolean; children: ReactNode }) {
  return (
    <div className={`${dark ? "dark" : ""} h-screen w-full overflow-hidden`}>
      <div
        className="h-full w-full bg-white dark:bg-[#171725] flex flex-col items-center justify-center gap-[12px]"
        style={{ fontFamily: MONO }}
      >
        {children}
      </div>
    </div>
  );
}
