import { useEffect, useState } from "react";
import { api } from "../lib/api";
import type { EventState, EventStatus, MatchupMethod } from "../lib/types";
import type { EventBundle } from "../lib/api";
import { CompletedDashboard } from "./CompletedDashboard";

const MONO = "var(--font-sf-mono)";

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

export function SharedResults({ eventId }: { eventId: string }) {
  const [event, setEvent] = useState<EventState | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.getSharedEvent(eventId)
      .then((bundle) => setEvent(toEventState(bundle)))
      .catch((e) => setError(e instanceof Error ? e.message : "Failed to load event."));
  }, [eventId]);

  if (error) {
    return (
      <div
        className="min-h-screen w-full bg-[#171725] flex flex-col items-center justify-center gap-[16px] p-[24px] text-center"
        style={{ fontFamily: MONO }}
      >
        <p className="text-[var(--destructive)] text-[13px]">{error}</p>
        <p className="text-white/30 text-[11px] tracking-[1px] uppercase">
          This link may be invalid or the event may not be completed yet.
        </p>
      </div>
    );
  }

  if (!event) {
    return (
      <div
        className="min-h-screen w-full bg-[#171725] flex items-center justify-center"
        style={{ fontFamily: MONO }}
      >
        <p className="text-white/30 text-[12px] tracking-[2px] uppercase">Loading results…</p>
      </div>
    );
  }

  return (
    <div className="dark h-screen w-full overflow-hidden">
      <div className="h-full w-full bg-[#171725] flex flex-col">
        <CompletedDashboard
          event={event}
          isPublic
          fetchInsights={(id, force) => api.getSharedInsights(id, force)}
        />
      </div>
    </div>
  );
}
