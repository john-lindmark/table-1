import { useState } from "react";
import { acrossTheTable } from "../lib/seating";
import { Segmented } from "./kit";
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

/** Seat centres (as % of the box) on a rectangle: seat k at −90° + 360°·(k + ½)/n, so opposite seats mirror. */
export function seatPositions(n: number, chipW = 28, chipH = 12): { x: number; y: number }[] {
  const ax = 50 - chipW / 2 - 1;
  const ay = 50 - chipH / 2 - 1;
  return Array.from({ length: n }, (_, k) => {
    const t = -Math.PI / 2 + (2 * Math.PI * (k + 0.5)) / n;
    const cx = Math.cos(t);
    const sy = Math.sin(t);
    const r = Math.min(Math.abs(cx) < 1e-9 ? Infinity : ax / Math.abs(cx), Math.abs(sy) < 1e-9 ? Infinity : ay / Math.abs(sy));
    return { x: 50 + r * cx, y: 50 + r * sy };
  });
}

/**
 * Each pod drawn as a table: seats clockwise from the top left (two to a side for eight, so seat 1 sits straight
 * across from seat 5). Lines join round 1 opponents; the middle says which way the chosen pack passes
 * (left = clockwise, to the next seat number).
 */
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
  const [pack, setPack] = useState<1 | 2 | 3>(1);
  if (!pods.length) {
    return <div className="bg-t1-surface px-4 py-4 t1-label">Nobody is seated yet</div>;
  }
  const left = pack % 2 === 1;
  return (
    <div className="flex flex-col gap-px">
      <Segmented
        label="Pack"
        value={pack}
        onChange={setPack}
        options={[
          { value: 1, label: "Pack 1" },
          { value: 2, label: "Pack 2" },
          { value: 3, label: "Pack 3" },
        ]}
      />
      {pods.map((pod) => {
        const note = roundOneNote(pod, formatName, participants, teams);
        const seats = [...pod.seats].sort((a, b) => a.seat - b.seat);
        const pos = seatPositions(seats.length);
        const index = new Map(seats.map((s, i) => [s.participant_id, i]));
        const { pairs, bye } = roundOnePairs(pod, formatName, participants, teams);
        return (
          <div key={pod.pod_id} className="flex flex-col gap-px">
            <div className="bg-t1-surface px-4 py-2 flex justify-between t1-label">
              <span>{pods.length > 1 ? pod.name : "Seating"}</span>
              <span>{pod.seats.length} drafters</span>
            </div>
            <div className="bg-t1-surface py-3">
              <div
                className="relative mx-auto w-full max-w-[520px] aspect-[1/0.92]"
                role="img"
                aria-label={`Table: ${seats.map((s) => `seat ${s.seat} ${s.display_name}`).join(", ")}. Pack ${pack} passes ${left ? "left" : "right"}.`}
              >
                <div className="absolute bg-t1-bg border border-t1-disabled" style={{ left: "27%", right: "27%", top: "15%", bottom: "15%" }} />
                <svg className="absolute inset-0 w-full h-full" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden>
                  {pairs.map(([a, b]) => {
                    const i = index.get(a);
                    const j = index.get(b);
                    if (i == null || j == null) return null;
                    const mine = a === highlightParticipantId || b === highlightParticipantId;
                    return (
                      <line
                        key={`${a}-${b}`}
                        x1={pos[i].x}
                        y1={pos[i].y}
                        x2={pos[j].x}
                        y2={pos[j].y}
                        vectorEffect="non-scaling-stroke"
                        strokeWidth={mine ? 2 : 1}
                        className={mine ? "stroke-t1-accent" : "stroke-t1-disabled"}
                      />
                    );
                  })}
                </svg>
                <div className="absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 bg-t1-bg px-3 py-1.5 text-center">
                  <div className="t1-label">Pack {pack}</div>
                  <div className="text-[13px] font-bold whitespace-nowrap">{left ? "↻ Pass left" : "↺ Pass right"}</div>
                </div>
                {seats.map((s, i) => {
                  const mine = s.participant_id === highlightParticipantId;
                  return (
                    <div
                      key={s.participant_id}
                      className={`absolute -translate-x-1/2 -translate-y-1/2 w-[28%] h-[12%] min-h-[42px] px-2 flex flex-col justify-center border ${mine ? "bg-t1-surface-hover border-t1-accent" : "bg-t1-bg border-t1-disabled"}`}
                      style={{ left: `${pos[i].x}%`, top: `${pos[i].y}%` }}
                    >
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
            {note && <div className="bg-t1-surface px-4 py-2.5 text-[11px] leading-[16px] text-t1-muted">{note}</div>}
          </div>
        );
      })}
    </div>
  );
}
