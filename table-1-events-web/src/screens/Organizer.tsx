import { useMemo, useState } from "react";
import { useEvent } from "../lib/useEvent";
import {
  recordRound,
  setParticipantStatus,
  setResultAsOrganizer,
  setTimer,
  startRound,
  writeAudit,
} from "../lib/api";
import { assignSeats, pairRound } from "../lib/pairings";
import { supabase } from "../lib/supabaseClient";
import { MatchRow, matchState } from "../components/MatchRow";
import { StandingsTable } from "../components/StandingsTable";
import {
  Bar,
  BigAction,
  ClockFace,
  GhostAction,
  Notice,
  Screen,
  TimerProgress,
} from "../components/kit";
import { SharePanel } from "../components/SharePanel";
import type { Match } from "../lib/types";

type Tab = "round" | "standings" | "players";

export function Organizer({ eventId, onExit }: { eventId: string; onExit: () => void }) {
  const { bundle, error, sync, mutate, refetch } = useEvent(eventId);
  const [tab, setTab] = useState<Tab>("round");
  const [busy, setBusy] = useState(false);
  const [confirming, setConfirming] = useState(false);

  const participants = useMemo(
    () => new Map((bundle?.participants ?? []).map((p) => [p.id, p])),
    [bundle],
  );

  if (error && !bundle) {
    return (
      <Screen>
        <Bar title="Could not load event" />
        <Notice tone="error">{error}</Notice>
        <GhostAction label="Retry" onClick={refetch} />
      </Screen>
    );
  }
  if (!bundle) {
    return (
      <Screen>
        <div className="flex-1 flex items-center justify-center t1-label">Loading event…</div>
      </Screen>
    );
  }

  const { event, rounds } = bundle;
  const activeRound = rounds.find((r) => r.status === "active") ?? null;
  const recordedRounds = rounds.filter((r) => r.status === "recorded");
  const nextRoundNumber = recordedRounds.length + 1;
  const isFinalRound = (activeRound?.number ?? nextRoundNumber) >= event.numberOfRounds;
  const activeCount = bundle.participants.filter((p) => p.status === "active").length;

  const allEntered =
    !!activeRound &&
    activeRound.matches.length > 0 &&
    activeRound.matches.every((m) => {
      const { state } = matchState(m);
      return state === "decisive" || state === "draw";
    });
  const anyInvalid =
    !!activeRound && activeRound.matches.some((m) => matchState(m).state === "invalid");

  /* ── actions ───────────────────────────────────────────────────────────── */

  async function handleStartRound() {
    if (activeCount < 2) return;
    setBusy(true);
    try {
      // Round 1 also fixes the draft seating order.
      if (nextRoundNumber === 1) {
        const seats = assignSeats(
          bundle!.participants.filter((p) => p.status === "active").map((p) => p.id),
        );
        await Promise.all(
          [...seats.entries()].map(([id, seat]) =>
            supabase.from("participants").update({ seat }).eq("id", id),
          ),
        );
      }
      const proposed = pairRound({
        participants: bundle!.participants,
        rounds: bundle!.rounds,
        roundNumber: nextRoundNumber,
      });
      await startRound(eventId, nextRoundNumber, proposed, event.roundLengthSeconds);
      await writeAudit({
        eventId,
        action: "round.started",
        targetType: "round",
        after: { round: nextRoundNumber, tables: proposed.length },
      });
      await refetch();
    } finally {
      setBusy(false);
    }
  }

  function cycleResult(match: Match, side: 0 | 1) {
    const current = match.sides.find((s) => s.side === side)?.gameWins ?? 0;
    const next = (current + 1) % 3;
    const side0 = side === 0 ? next : match.sides.find((s) => s.side === 0)?.gameWins ?? 0;
    const side1 = side === 1 ? next : match.sides.find((s) => s.side === 1)?.gameWins ?? 0;

    mutate(
      (prev) => ({
        ...prev,
        rounds: prev.rounds.map((r) =>
          r.id !== match.roundId
            ? r
            : {
                ...r,
                matches: r.matches.map((m) =>
                  m.id !== match.id
                    ? m
                    : {
                        ...m,
                        status: "confirmed",
                        sides: m.sides.map((s) =>
                          s.side === side ? { ...s, gameWins: next } : s,
                        ),
                      },
                ),
              },
        ),
      }),
      () => setResultAsOrganizer(match, side0, side1),
    );
  }

  async function handleRecord() {
    if (!activeRound) return;
    setBusy(true);
    try {
      await recordRound(eventId, activeRound.id, isFinalRound);
      await writeAudit({
        eventId,
        action: isFinalRound ? "event.completed" : "round.recorded",
        targetType: "round",
        targetId: activeRound.id,
      });
      setConfirming(false);
      await refetch();
      if (isFinalRound) setTab("standings");
    } finally {
      setBusy(false);
    }
  }

  function toggleTimer() {
    if (!activeRound) return;
    const running = activeRound.timerStatus === "running";
    const now = Date.now();
    const remaining = running
      ? activeRound.timerRemainingAtChange -
        Math.floor((now - new Date(activeRound.timerLastStartedAt!).getTime()) / 1000)
      : activeRound.timerRemainingAtChange;

    mutate(
      (prev) => ({
        ...prev,
        rounds: prev.rounds.map((r) =>
          r.id !== activeRound.id
            ? r
            : running
              ? {
                  ...r,
                  timerStatus: "paused",
                  timerRemainingAtChange: remaining,
                  timerLastStartedAt: null,
                }
              : { ...r, timerStatus: "running", timerLastStartedAt: new Date(now).toISOString() },
        ),
      }),
      () =>
        setTimer(
          activeRound.id,
          running
            ? {
                timer_status: "paused",
                timer_remaining_at_change: remaining,
                timer_last_started_at: null,
              }
            : { timer_status: "running", timer_last_started_at: new Date(now).toISOString() },
        ),
    );
  }

  /* ── render ────────────────────────────────────────────────────────────── */

  const actionLabel = !activeRound
    ? event.status === "completed"
      ? "Event complete"
      : `Start Round ${nextRoundNumber}`
    : isFinalRound
      ? "Complete Event"
      : `Record Round ${activeRound.number}`;

  return (
    <Screen>
      <Bar
        title={event.name}
        subtitle={`${event.shortCode} · Round ${activeRound?.number ?? recordedRounds.length} of ${event.numberOfRounds} · ${activeCount} players`}
        right={
          <button onClick={onExit} className="t1-label shrink-0">
            Events
          </button>
        }
      />

      <div className="flex gap-px shrink-0">
        {(["round", "standings", "players"] as Tab[]).map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={`flex-1 px-4 py-3 text-[11px] uppercase tracking-[1px] ${
              tab === t ? "bg-t1-text text-t1-bg" : "bg-t1-surface text-t1-muted"
            }`}
          >
            {t}
          </button>
        ))}
      </div>

      {sync === "error" && <Notice tone="error">{error ?? "Something failed to save."}</Notice>}

      <div className="flex-1 min-h-0 overflow-y-auto flex flex-col gap-px">
        {tab === "round" && (
          <>
            {!activeRound && event.status !== "completed" && (
              <Notice tone="info">
                {nextRoundNumber === 1
                  ? `${activeCount} players seated. Starting round 1 assigns draft seats and pairs the first round.`
                  : `Round ${recordedRounds.length} recorded. Pair round ${nextRoundNumber} when the table is ready.`}
              </Notice>
            )}
            {activeRound?.matches.map((m) => (
              <MatchRow
                key={m.id}
                match={m}
                participants={participants}
                canEdit
                onCycle={(side) => cycleResult(m, side)}
              />
            ))}
            {event.status === "completed" && (
              <StandingsTable participants={bundle.participants} rounds={bundle.rounds} />
            )}
          </>
        )}

        {tab === "standings" && (
          <StandingsTable participants={bundle.participants} rounds={bundle.rounds} />
        )}

        {tab === "players" && (
          <>
            <SharePanel shortCode={event.shortCode} eventId={event.id} />
            {bundle.participants.map((p) => (
              <div key={p.id} className="bg-t1-surface px-4 py-3 flex items-center gap-3">
                <span className="w-6 t1-label">{p.seat ?? "–"}</span>
                <span
                  className={`flex-1 text-[13px] truncate ${
                    p.status === "dropped" ? "line-through opacity-50" : ""
                  }`}
                >
                  {p.displayName}
                </span>
                <button
                  onClick={() =>
                    setParticipantStatus(
                      p.id,
                      p.status === "active" ? "dropped" : "active",
                      activeRound?.number ?? null,
                    ).then(refetch)
                  }
                  className="t1-label"
                >
                  {p.status === "active" ? "Drop" : "Undrop"}
                </button>
              </div>
            ))}
          </>
        )}
      </div>

      {activeRound && (
        <>
          <div className="shrink-0 bg-t1-bg py-4 flex flex-col gap-3">
            <ClockFace round={activeRound} />
            <div className="flex gap-px px-0">
              <GhostAction
                label={activeRound.timerStatus === "running" ? "Pause" : "Start clock"}
                onClick={toggleTimer}
              />
            </div>
          </div>
          <TimerProgress round={activeRound} />
        </>
      )}

      {event.status !== "completed" && (
        <BigAction
          label={actionLabel}
          busy={busy}
          disabled={activeRound ? !allEntered || anyInvalid : activeCount < 2}
          onClick={activeRound ? () => setConfirming(true) : handleStartRound}
        />
      )}

      {confirming && (
        <div className="fixed inset-0 z-50 flex items-center justify-center">
          <div className="absolute inset-0 bg-black/70" onClick={() => setConfirming(false)} />
          <div className="relative bg-t1-bg w-[90%] max-w-[380px] p-6 flex flex-col gap-4 border border-t1-surface">
            <p className="text-[15px]">{isFinalRound ? "Complete this event?" : `Record round ${activeRound?.number}?`}</p>
            <p className="text-[12px] leading-[18px] text-t1-muted">
              This finalizes every result in the round and advances the event. Results can still be
              corrected afterwards, and every change is written to the audit log.
            </p>
            <div className="flex gap-px">
              <GhostAction label="Cancel" onClick={() => setConfirming(false)} />
              <button
                onClick={handleRecord}
                disabled={busy}
                className="flex-1 bg-t1-text text-t1-bg px-4 py-3 text-[11px] uppercase tracking-[1px] disabled:opacity-60"
              >
                {busy ? "Recording…" : "Confirm"}
              </button>
            </div>
          </div>
        </div>
      )}
    </Screen>
  );
}
