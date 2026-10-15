import { useEvent } from "../lib/useEvent";
import { StandingsTable } from "../components/StandingsTable";
import { Bar, ClockFace, Notice, Screen } from "../components/kit";
import { MatchRow } from "../components/MatchRow";
import { useMemo } from "react";

/** Read-only, no sign-in. This is the link people share. */
export function PublicStandings({ eventId }: { eventId: string }) {
  const { bundle, error } = useEvent(eventId);
  const participants = useMemo(
    () => new Map((bundle?.participants ?? []).map((p) => [p.id, p])),
    [bundle],
  );

  if (error && !bundle) {
    return (
      <Screen>
        <Bar title="Event not found" />
        <Notice tone="error">{error}</Notice>
      </Screen>
    );
  }
  if (!bundle) {
    return (
      <Screen>
        <div className="flex-1 flex items-center justify-center t1-label">Loading…</div>
      </Screen>
    );
  }

  const { event, rounds } = bundle;
  const activeRound = rounds.find((r) => r.status === "active") ?? null;

  return (
    <Screen>
      <Bar
        title={event.name}
        subtitle={
          event.status === "completed"
            ? "Final standings"
            : `Round ${activeRound?.number ?? event.currentRound} of ${event.numberOfRounds}`
        }
      />
      {activeRound && event.showClock && (
        <div className="bg-t1-bg py-4">
          <ClockFace round={activeRound} size="small" />
        </div>
      )}
      <StandingsTable participants={bundle.participants} rounds={rounds} />
      {activeRound && (
        <>
          <div className="bg-t1-surface px-4 py-2 t1-label">Current pairings</div>
          {activeRound.matches.map((m) => (
            <MatchRow key={m.id} match={m} participants={participants} canEdit={false} onCycle={() => {}} />
          ))}
        </>
      )}
    </Screen>
  );
}
