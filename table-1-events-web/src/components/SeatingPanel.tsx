import { acrossTheTable } from "../lib/seating";
import { membersOf, pairTeamDraftRound } from "../lib/teams";
import type { EventTeam, FormatName, Participant, SeatingPod } from "../lib/types";

/** "Round 1 pairs across the table: 1 v 5, 2 v 6, 3 v 7, 4 v 8." for one pod. */
export function roundOneNote(
  pod: SeatingPod,
  formatName: FormatName,
  participants: Participant[],
  teams: EventTeam[] | null,
): string | null {
  const seatOf = new Map(pod.seats.map((s) => [s.participant_id, s.seat]));
  if (formatName === "team_draft") {
    const ordered = [...(teams ?? [])].sort((a, b) => a.order - b.order);
    if (ordered.length !== 2) return null;
    const pairs = pairTeamDraftRound(membersOf(ordered[0].id, participants), membersOf(ordered[1].id, participants), 1)
      .filter((m) => !m.isBye && m.side1ParticipantId)
      .map((m) => [seatOf.get(m.side0ParticipantId), seatOf.get(m.side1ParticipantId!)])
      .filter(([a, b]) => a != null && b != null)
      .map(([a, b]) => `${Math.min(a!, b!)} v ${Math.max(a!, b!)}`);
    return pairs.length ? `Round 1 pairs each seat with the other team: ${pairs.join(", ")}.` : null;
  }
  const { pairs, bye } = acrossTheTable(
    pod.seats.map((s) => ({ participantId: s.participant_id, podId: pod.pod_id, seat: s.seat })),
  );
  if (!pairs.length) return null;
  const text = pairs.map(([a, b]) => `${seatOf.get(a)} v ${seatOf.get(b)}`).join(", ");
  return `Round 1 pairs across the table: ${text}.${bye ? ` Seat ${seatOf.get(bye)} has the bye.` : ""}`;
}

/** Pods with numbered seats, team per seat, pass directions and the round-1 note. */
export function SeatingPanel({
  pods,
  formatName,
  participants,
  teams,
  highlightParticipantId,
}: {
  pods: SeatingPod[];
  formatName: FormatName;
  participants: Participant[];
  teams: EventTeam[] | null;
  highlightParticipantId?: string | null;
}) {
  if (!pods.length) {
    return <div className="bg-t1-surface px-4 py-4 t1-label">Nobody is seated yet</div>;
  }
  return (
    <div className="flex flex-col gap-px">
      {pods.map((pod) => {
        const note = roundOneNote(pod, formatName, participants, teams);
        return (
          <div key={pod.pod_id} className="flex flex-col gap-px">
            <div className="bg-t1-surface px-4 py-2 flex justify-between t1-label">
              <span>{pods.length > 1 ? pod.name : "Seating"}</span>
              <span>{pod.seats.length} drafters</span>
            </div>
            <ol className="flex flex-col gap-px">
              {pod.seats.map((s) => {
                const mine = s.participant_id === highlightParticipantId;
                return (
                  <li
                    key={s.participant_id}
                    className={`px-4 py-2.5 flex items-center gap-3 text-[13px] ${mine ? "bg-t1-accent text-t1-ink" : "bg-t1-surface"}`}
                  >
                    <span className={`w-6 tabular-nums ${mine ? "" : "text-t1-accent"}`}>{s.seat}</span>
                    <span className="flex-1 min-w-0 truncate">{s.display_name}</span>
                    {s.team && <span className={`t1-label truncate max-w-[40%] ${mine ? "text-t1-ink!" : ""}`}>{s.team}</span>}
                  </li>
                );
              })}
            </ol>
            <div className="bg-t1-surface px-4 py-2.5 t1-label">Pack 1 passes left · Pack 2 right · Pack 3 left</div>
            {note && <div className="bg-t1-surface px-4 py-2.5 text-[11px] leading-[16px] text-t1-muted">{note}</div>}
          </div>
        );
      })}
    </div>
  );
}
