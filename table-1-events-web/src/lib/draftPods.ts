// Drafts with several pods on the web (contract/draft-pods-2026-11-09.md): what the clients say about a pick and
// about round 1, on top of the engine's own rules (seating.ts podPlan / podLabel / roundOnePlan, playoffs.ts
// draftRounds). Cases: testdata/draft-pods/cases.json.
import { draftRounds } from "./playoffs";
import { podPlan, roundOnePlan } from "./seating";
import type { SeatingPod } from "./types";

export type PodPairing = "pod" | "cross";

/** The Automatic rounds switch's detail for a draft: "Auto · 3 rounds for pods of 9". */
export function draftAutoLabel(players: number, pods: number | null, pairing: PodPairing): string {
  if (players < 2) return "Auto · set when round 1 is paired";
  const sizes = podPlan(players, pods);
  const n = draftRounds(sizes, pairing);
  const rs = `${n} round${n === 1 ? "" : "s"}`;
  if (pairing === "pod" && sizes.length > 1) return `Auto · ${rs} for pods of ${Math.max(...sizes)}`;
  return `Auto · ${rs} for ${players} players`;
}

const seated = (pods: SeatingPod[]) =>
  pods.map((pod) => pod.seats.map((s) => ({ participantId: s.participant_id, podId: pod.pod_id, seat: s.seat })));

/** The participant with round 1's bye across every pod (only when the event is odd), or null. */
export function roundOneBye(pods: SeatingPod[]): string | null {
  return roundOnePlan(seated(pods)).bye;
}

/** The note under pod `index`: "Round 1 pairs across the table: 1 v 4, 2 v 5, 3 v 6. Seat 7 plays Pod 2's seat 7." */
export function podNote(pods: SeatingPod[], index: number): string {
  const plan = roundOnePlan(seated(pods));
  const seatOf = new Map(pods.flatMap((pod, p) => pod.seats.map((s) => [s.participant_id, { p, seat: s.seat }] as const)));
  const pod = plan.pods[index];
  const pairs = pod.pairs.map(([a, b]) => `${seatOf.get(a)!.seat} v ${seatOf.get(b)!.seat}`).join(", ");
  let text = pairs ? `Round 1 pairs across the table: ${pairs}.` : "Round 1 pairs across the table.";
  const left = pod.left;
  if (left) {
    const mine = seatOf.get(left)!;
    if (plan.bye === left) text += ` Seat ${mine.seat} has the bye.`;
    else {
      const pair = plan.across.find(([a, b]) => a === left || b === left);
      if (pair) {
        const other = seatOf.get(pair[0] === left ? pair[1] : pair[0])!;
        text += ` Seat ${mine.seat} plays ${pods[other.p].name ?? `Pod ${other.p + 1}`}'s seat ${other.seat}.`;
      }
    }
  }
  return text;
}

/** Short code for a standings row: "P1" from "Pod 1", else the pod's place. */
export function podCode(name: string | null | undefined, index: number): string {
  const n = name?.trim().split(/\s+/).at(-1);
  return n && /^\d+$/.test(n) ? `P${n}` : `P${index + 1}`;
}
