import { useCallback, useEffect, useState } from "react";
import { Bar, ClockFace, Notice, Screen } from "../components/kit";
import {
  errorMessage,
  fetchPublicEvent,
  fetchPublicStandings,
  subscribeToEvent,
  type PublicEvent,
  type PublicPairing,
  type PublicStandingRow,
} from "../lib/api";
import { formatPct } from "../lib/standings";

/**
 * Read-only, no sign-in. This is the link people share (contract/privacy-lockdown-2026-10-18.md): event_public
 * gives the event, the clock and current pairings by name, and events-engine the ranked standings. No player list
 * or account ids reach this page; a private event reads "That event isn't available".
 */
export function PublicStandings({ eventId }: { eventId: string }) {
  const [event, setEvent] = useState<PublicEvent | null>(null);
  const [rows, setRows] = useState<PublicStandingRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      const [e, s] = await Promise.all([fetchPublicEvent(eventId), fetchPublicStandings(eventId)]);
      setEvent(e);
      setRows(s);
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [eventId]);

  useEffect(() => {
    void load();
    const unsubscribe = subscribeToEvent(eventId, () => void load());
    const poll = window.setInterval(() => void load(), 20000);
    return () => {
      unsubscribe();
      window.clearInterval(poll);
    };
  }, [eventId, load]);

  if (error && !event) {
    return (
      <Screen>
        <Bar title="Event not found" />
        <Notice tone="error">{error}</Notice>
      </Screen>
    );
  }
  if (!event || !rows) {
    return (
      <Screen>
        <div className="flex-1 flex items-center justify-center t1-label">Loading…</div>
      </Screen>
    );
  }

  const round = event.round;
  return (
    <Screen>
      <Bar
        title={event.name}
        subtitle={
          event.status === "completed"
            ? "Final standings"
            : `Round ${round?.number ?? event.currentRound} of ${event.numberOfRounds}`
        }
      />
      {round && event.showClock && (
        <div className="bg-t1-bg py-4">
          <ClockFace round={round} size="small" />
        </div>
      )}
      <PublicStandingsTable rows={rows} />
      {event.pairings.length > 0 && (
        <>
          <div className="bg-t1-surface px-4 py-2 t1-label">Current pairings</div>
          {event.pairings.map((m) => (
            <PairingRow key={m.matchId} match={m} />
          ))}
        </>
      )}
    </Screen>
  );
}

function PublicStandingsTable({ rows }: { rows: PublicStandingRow[] }) {
  if (rows.length === 0) return <div className="bg-t1-surface px-4 py-6 t1-label">No players yet</div>;
  return (
    <div className="flex flex-col gap-px">
      <div className="bg-t1-surface px-4 py-2 flex items-center gap-3 t1-label">
        <span className="w-6 shrink-0">#</span>
        <span className="flex-1">Player</span>
        <span className="w-12 text-right">Rec</span>
        <span className="w-8 text-right">Pts</span>
        <span className="w-14 text-right">OMW</span>
        <span className="w-14 text-right">GW</span>
      </div>
      {rows.map((r) => (
        <div key={r.participantId} className="bg-t1-surface px-4 py-3 flex items-center gap-3 text-[12px] tabular-nums">
          <span className="w-6 shrink-0 text-t1-muted">{r.rank}</span>
          <span className={`flex-1 min-w-0 truncate ${r.status === "dropped" ? "line-through opacity-50" : ""}`}>
            {r.displayName}
          </span>
          <span className="w-12 text-right">
            {r.matchDraws > 0 ? `${r.matchWins}-${r.matchLosses}-${r.matchDraws}` : `${r.matchWins}-${r.matchLosses}`}
          </span>
          <span className="w-8 text-right font-bold">{r.matchPoints}</span>
          <span className="w-14 text-right text-t1-muted">{formatPct(r.omw)}</span>
          <span className="w-14 text-right text-t1-muted">{formatPct(r.gw)}</span>
        </div>
      ))}
      <div className="bg-t1-surface px-4 py-3 text-[10px] leading-[15px] text-t1-muted">
        Ordered by match points, then opponents' match-win %, then game-win %, then opponents' game-win %. Percentages
        floored at 33% per the Magic Tournament Rules.
      </div>
    </div>
  );
}

function PairingRow({ match }: { match: PublicPairing }) {
  const [a, b] = [match.sides.find((s) => s.side === 0), match.sides.find((s) => s.side === 1)];
  const scored = match.status !== "pending";
  return (
    <div className="bg-t1-surface px-4 py-3 flex items-center gap-3 text-[12px]">
      <span className="w-10 shrink-0 t1-label">{match.isBye ? "Bye" : `T${match.tableNumber ?? "–"}`}</span>
      <span className="flex-1 min-w-0 truncate">{a?.displayName ?? "—"}</span>
      {!match.isBye && (
        <>
          <span className="w-16 shrink-0 text-center tabular-nums text-t1-muted">
            {scored ? `${a?.gameWins ?? 0}–${b?.gameWins ?? 0}${match.gameDraws > 0 ? `–${match.gameDraws}` : ""}` : "vs"}
          </span>
          <span className="flex-1 min-w-0 truncate text-right">{b?.displayName ?? "—"}</span>
        </>
      )}
    </div>
  );
}
