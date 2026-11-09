import { useState } from "react";
import { computeStandings, formatPct, recordLabel } from "../lib/standings";
import { podCode } from "../lib/draftPods";
import type { EventPod } from "../lib/api";
import type { Participant, RoundWithMatches } from "../lib/types";
import { Segmented } from "./kit";
import { Avatar } from "./Avatar";
import { useOpenProfile } from "../lib/personLink";

export function StandingsTable({
  participants,
  rounds,
  highlightParticipantId,
  compact,
  teamNames,
  pods,
}: {
  participants: Participant[];
  rounds: RoundWithMatches[];
  highlightParticipantId?: string | null;
  compact?: boolean;
  /** Team events: team id → name, shown as a tag next to each player. */
  teamNames?: Map<string, string>;
  /** Drafts: the event's pods. With 2+ in play, each row is tagged with its pod and a filter shows one pod. */
  pods?: EventPod[];
}) {
  const [podFilter, setPodFilter] = useState<string>("");
  const inPlay = new Set(participants.map((p) => p.podId).filter(Boolean));
  const shownPods = (pods ?? []).filter((d) => inPlay.has(d.id)).sort((a, b) => a.displayOrder - b.displayOrder);
  const podTags = shownPods.length > 1 ? new Map(shownPods.map((d, i) => [d.id, podCode(d.name, i)])) : null;
  const userOf = new Map(participants.map((p) => [p.id, p.userId ?? null]));
  const openProfile = useOpenProfile("standings");
  const teamOf = new Map<string, string | null>(participants.map((p) => [p.id, p.teamId ? teamNames?.get(p.teamId) ?? null
    : podTags && p.podId ? podTags.get(p.podId) ?? null : null]));
  const podOf = new Map(participants.map((p) => [p.id, p.podId]));
  const standings = computeStandings(participants, rounds)
    .filter((row) => !podTags || !podFilter || podOf.get(row.participantId) === podFilter);
  if (standings.length === 0) {
    return <div className="bg-t1-surface px-4 py-6 t1-label">No players yet</div>;
  }

  return (
    <div className="flex flex-col gap-px">
      {podTags && (
        <Segmented value={podFilter} onChange={setPodFilter} scroll
                   options={[{ value: "", label: "All" }, ...shownPods.map((d) => ({ value: d.id, label: d.name }))]} />
      )}
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
        const open = openProfile(userOf.get(row.participantId));
        return (
          <div
            key={row.participantId}
            role={open ? "link" : undefined}
            tabIndex={open ? 0 : undefined}
            onClick={open}
            onKeyDown={open && ((e) => { if (e.key === "Enter") open(); })}
            className={`px-4 py-3 flex items-center gap-3 text-[12px] tabular-nums ${
              mine ? "bg-t1-accent text-t1-ink" : "bg-t1-surface"
            } ${open && !mine ? "cursor-pointer hover:bg-t1-surface-hover" : open ? "cursor-pointer" : ""}`}
          >
            <span className={`w-6 shrink-0 ${mine ? "" : "text-t1-muted"}`}>{row.rank}</span>
            <span className="flex-1 min-w-0 flex items-center gap-2">
              <Avatar name={row.displayName} userId={userOf.get(row.participantId)} />
              <span className={`truncate ${row.status === "dropped" ? "line-through opacity-50" : ""}`}>
                {row.displayName}
              </span>
              {teamOf.get(row.participantId) && (
                <span
                  className={`shrink-0 max-w-[45%] truncate text-[9px] uppercase tracking-[1px] px-1.5 py-px border ${
                    mine ? "border-t1-ink/40" : "border-t1-muted/40 text-t1-muted"
                  }`}
                >
                  {teamOf.get(row.participantId)}
                </span>
              )}
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
