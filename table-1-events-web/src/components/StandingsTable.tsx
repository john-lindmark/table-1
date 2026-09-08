import { computeStandings, formatPct, recordLabel } from "../lib/standings";
import type { Participant, RoundWithMatches } from "../lib/types";

export function StandingsTable({
  participants,
  rounds,
  highlightParticipantId,
  compact,
}: {
  participants: Participant[];
  rounds: RoundWithMatches[];
  highlightParticipantId?: string | null;
  compact?: boolean;
}) {
  const standings = computeStandings(participants, rounds);
  if (standings.length === 0) {
    return <div className="bg-t1-surface px-4 py-6 t1-label">No players yet</div>;
  }

  return (
    <div className="flex flex-col gap-px">
      <div className="bg-t1-surface px-4 py-2 flex items-center gap-3 t1-label">
        <span className="w-6 shrink-0">#</span>
        <span className="flex-1">Player</span>
        <span className="w-12 text-right">Rec</span>
        <span className="w-8 text-right">Pts</span>
        {!compact && <span className="w-14 text-right">OMW</span>}
        {!compact && <span className="w-14 text-right">GW</span>}
      </div>
      {standings.map((row) => {
        const mine = row.participantId === highlightParticipantId;
        return (
          <div
            key={row.participantId}
            className={`px-4 py-3 flex items-center gap-3 text-[12px] tabular-nums ${
              mine ? "bg-t1-accent text-t1-ink" : "bg-t1-surface"
            }`}
          >
            <span className={`w-6 shrink-0 ${mine ? "" : "text-t1-muted"}`}>{row.rank}</span>
            <span
              className={`flex-1 truncate ${row.status === "dropped" ? "line-through opacity-50" : ""}`}
            >
              {row.displayName}
            </span>
            <span className="w-12 text-right">{recordLabel(row)}</span>
            <span className="w-8 text-right font-bold">{row.matchPoints}</span>
            {!compact && (
              <span className={`w-14 text-right ${mine ? "" : "text-t1-muted"}`}>
                {formatPct(row.opponentMatchWinPct)}
              </span>
            )}
            {!compact && (
              <span className={`w-14 text-right ${mine ? "" : "text-t1-muted"}`}>
                {formatPct(row.gameWinPct)}
              </span>
            )}
          </div>
        );
      })}
      {!compact && (
        <div className="bg-t1-surface px-4 py-3 text-[10px] leading-[15px] text-t1-muted">
          Ordered by match points, then opponents' match-win %, then game-win %, then opponents'
          game-win %. Percentages floored at 33% per the Magic Tournament Rules.
        </div>
      )}
    </div>
  );
}
