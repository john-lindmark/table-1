import { useEffect, useState } from "react";
import { acrossTheTable } from "../lib/seating";
import { TableLayout } from "../lib/tableLayout";
import { membersOf, pairTeamDraftRound } from "../lib/teams";
import type { EventTeam, FormatName, Participant, SeatingPod } from "../lib/types";

/** Round 1 opponents in one pod (participant ids), and who has the bye. */
export function roundOnePairs(
  pod: SeatingPod,
  formatName: FormatName,
  participants: Participant[],
  teams: EventTeam[] | null,
): { pairs: [string, string][]; bye: string | null } {
  if (formatName === "team_draft") {
    const ordered = [...(teams ?? [])].sort((a, b) => a.order - b.order);
    if (ordered.length !== 2) return { pairs: [], bye: null };
    const inPod = new Set(pod.seats.map((s) => s.participant_id));
    const pairs = pairTeamDraftRound(membersOf(ordered[0].id, participants), membersOf(ordered[1].id, participants), 1)
      .filter((m) => !m.isBye && m.side1ParticipantId && inPod.has(m.side0ParticipantId))
      .map((m): [string, string] => [m.side0ParticipantId, m.side1ParticipantId!]);
    return { pairs, bye: null };
  }
  return acrossTheTable(pod.seats.map((s) => ({ participantId: s.participant_id, podId: pod.pod_id, seat: s.seat })));
}

/** "Round 1 pairs across the table: 1 v 5, 2 v 6, 3 v 7, 4 v 8." for one pod. */
export function roundOneNote(
  pod: SeatingPod,
  formatName: FormatName,
  participants: Participant[],
  teams: EventTeam[] | null,
): string | null {
  const seatOf = new Map(pod.seats.map((s) => [s.participant_id, s.seat]));
  const { pairs, bye } = roundOnePairs(pod, formatName, participants, teams);
  if (!pairs.length) return null;
  if (formatName === "team_draft") {
    const text = pairs
      .map(([a, b]) => [seatOf.get(a)!, seatOf.get(b)!])
      .map(([a, b]) => `${Math.min(a, b)} v ${Math.max(a, b)}`);
    return `Round 1 pairs each seat with the other team: ${text.join(", ")}.`;
  }
  const text = pairs.map(([a, b]) => `${seatOf.get(a)} v ${seatOf.get(b)}`).join(", ");
  return `Round 1 pairs across the table: ${text}.${bye ? ` Seat ${seatOf.get(bye)} has the bye.` : ""}`;
}

/**
 * Each pod drawn the way a draft table really seats people: one long table, players along both long sides and (when
 * the organizer turns it on) one at each end. Lines join round 1 opponents; the middle says which way each pack passes
 * (left = clockwise, to the next seat number: packs 1 and 3; pack 2 goes right). Only the drawing changes. Same as iOS
 * SeatingTable and Android PodTable.
 */
export function SeatingPanel({
  pods,
  formatName,
  participants,
  teams,
  highlightParticipantId,
  seatEnds = false,
}: {
  pods: SeatingPod[];
  formatName: FormatName;
  participants: Participant[];
  teams: EventTeam[] | null;
  highlightParticipantId?: string | null;
  seatEnds?: boolean;
}) {
  if (!pods.length) {
    return <div className="bg-t1-surface px-4 py-4 t1-label">Nobody is seated yet</div>;
  }
  return (
    <div className="flex flex-col gap-px">
      {pods.map((pod) => (
        <div key={pod.pod_id} className="flex flex-col gap-px">
          <div className="bg-t1-surface px-4 py-2 flex justify-between t1-label">
            <span>{pods.length > 1 ? pod.name : "Seating"}</span>
            <span>{pod.seats.length} drafters</span>
          </div>
          <PodTable pod={pod} formatName={formatName} participants={participants} teams={teams} highlight={highlightParticipantId ?? null} seatEnds={seatEnds} />
          {(() => {
            const note = roundOneNote(pod, formatName, participants, teams);
            return note && <div className="bg-t1-surface px-4 py-2.5 text-[11px] leading-[16px] text-t1-muted">{note}</div>;
          })()}
        </div>
      ))}
    </div>
  );
}

function PodTable({ pod, formatName, participants, teams, highlight, seatEnds }: {
  pod: SeatingPod; formatName: FormatName; participants: Participant[]; teams: EventTeam[] | null; highlight: string | null; seatEnds: boolean;
}) {
  const [box, setBox] = useState<HTMLDivElement | null>(null);
  const [width, setWidth] = useState(360);
  useEffect(() => {
    if (!box) return;
    const ro = new ResizeObserver(([e]) => setWidth(e.contentRect.width));
    ro.observe(box);
    return () => ro.disconnect();
  }, [box]);
  const seats = [...pod.seats].sort((a, b) => a.seat - b.seat);
  const index = new Map(seats.map((s, i) => [s.participant_id, i]));
  const { pairs, bye } = roundOnePairs(pod, formatName, participants, teams);
  const layout = new TableLayout(seats.length, seatEnds);
  const chipW = Math.min(140, (width - 24) * 0.36);
  const pos = layout.positions(width, chipW);
  const t = layout.tableRect(width, chipW);
  return (
    <div className="bg-t1-surface py-3">
      <div ref={setBox} className="relative mx-auto w-full max-w-[520px]" style={{ height: layout.height }} role="img"
           aria-label={`Table${layout.ends ? " with players at the ends" : ""}: ${seats.map((s) => `seat ${s.seat} ${s.display_name}`).join(", ")}. Packs 1 and 3 pass left, pack 2 passes right.`}>
        <div className="absolute bg-t1-bg border border-t1-disabled" style={{ left: t.x, top: t.y, width: t.w, height: t.h }} />
        <svg className="absolute inset-0 w-full h-full" aria-hidden>
          {pairs.map(([a, b]) => {
            const i = index.get(a);
            const j = index.get(b);
            if (i == null || j == null) return null;
            const mine = a === highlight || b === highlight;
            return <line key={`${a}-${b}`} x1={pos[i].x} y1={pos[i].y} x2={pos[j].x} y2={pos[j].y} strokeWidth={mine ? 2 : 1}
                         className={mine ? "stroke-t1-accent" : "stroke-t1-disabled"} />;
          })}
        </svg>
        <div className="absolute -translate-x-1/2 -translate-y-1/2 bg-t1-bg px-2.5 py-1.5 text-center" style={{ left: t.x + t.w / 2, top: t.y + t.h / 2 }}>
          <div className="text-[12px] font-bold whitespace-nowrap">↻ 1·3 left</div>
          <div className="text-[12px] text-t1-muted whitespace-nowrap">↺ 2 right</div>
        </div>
        {seats.map((s, i) => {
          const mine = s.participant_id === highlight;
          return (
            <div key={s.participant_id}
                 className={`absolute px-2 flex flex-col justify-center border ${mine ? "bg-t1-surface-hover border-t1-accent" : "bg-t1-bg border-t1-disabled"}`}
                 style={{ left: pos[i].x - chipW / 2, top: pos[i].y - TableLayout.CHIP_H / 2, width: chipW, height: TableLayout.CHIP_H }}>
              <span className="flex items-center gap-1.5 min-w-0">
                <span className="text-t1-accent text-[13px] font-bold tabular-nums">{s.seat}</span>
                {s.team && <span className="t1-label truncate">{s.team}</span>}
                {bye === s.participant_id && <span className="t1-label text-t1-warning!">Bye</span>}
              </span>
              <span className="text-[12px] truncate">{s.display_name}</span>
            </div>
          );
        })}
      </div>
    </div>
  );
}
