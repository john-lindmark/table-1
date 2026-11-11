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

/* ── Pods in lists (cases `sections`, `player_sections`) ─────────────────────────────────────────────────────── */

export interface PodRef { id: string; name: string | null }
/** One pod's share of a list: its matches or players, under "Pod 1", "Across pods" or "Not seated". */
export interface PodSection<T> { pod: string | null; title: string; items: T[] }

/** A pod's title: its name, else "Pod N" by its place among all the event's pods. */
export function podTitle(name: string | null | undefined, index: number): string {
  return name?.trim() ? name : `Pod ${index + 1}`;
}

/** "1 match", "4 matches". */
export const matchCount = (n: number) => `${n} match${n === 1 ? "" : "es"}`;

/** A draft's pods in order (one pod, other formats: none, so nothing is grouped). */
export function podRefs(formatName: string | null | undefined, pods: { id: string; name: string; displayOrder: number }[] | undefined): PodRef[] {
  if (formatName !== "draft") return [];
  return [...(pods ?? [])].sort((a, b) => a.displayOrder - b.displayOrder).map((p) => ({ id: p.id, name: p.name }));
}

/**
 * A round's matches under their pods (Live round, Earlier, Matchups), or null when the round isn't grouped:
 * playoffs, or fewer than two pods hold a player. A match sits in the pod all its players share (a bye in its
 * player's pod), else under Across pods, which comes last. Tables in order inside each, the bye last.
 */
export function podSections<M>(
  matches: M[],
  pods: PodRef[],
  podOf: Map<string, string | null | undefined>,
  stage: string | null | undefined,
  get: { players: (m: M) => (string | null | undefined)[]; table: (m: M) => number | null | undefined; isBye: (m: M) => boolean },
): PodSection<M>[] | null {
  const inPlay = new Set([...podOf.values()].filter(Boolean));
  const shown = pods.map((p, i) => ({ p, i })).filter(({ p }) => inPlay.has(p.id));
  if ((stage && stage !== "swiss") || shown.length < 2) return null;
  const podOfMatch = (m: M): string | null => {
    const ps = get.players(m).filter((x): x is string => !!x);
    const set = new Set(ps.map((x) => podOf.get(x) ?? ""));
    const [only] = [...set];
    return ps.length > 0 && set.size === 1 && only ? only : null;
  };
  const ordered = (ms: M[]) => ms.map((m, i) => ({ m, i }))
    .sort((a, b) => Number(get.isBye(a.m)) - Number(get.isBye(b.m)) || (get.table(a.m) ?? 0) - (get.table(b.m) ?? 0) || a.i - b.i)
    .map(({ m }) => m);
  const out: PodSection<M>[] = [];
  for (const { p, i } of shown) {
    const ms = matches.filter((m) => podOfMatch(m) === p.id);
    if (ms.length) out.push({ pod: p.id, title: podTitle(p.name, i), items: ordered(ms) });
  }
  const across = matches.filter((m) => podOfMatch(m) === null);
  if (across.length) out.push({ pod: null, title: "Across pods", items: ordered(across) });
  return out;
}

/** A list of players under their pods (seat order; no seat keeps list order), then Not seated, or null with fewer
 *  than two pods in play. */
export function playerSections<P>(players: P[], pods: PodRef[], pod: (p: P) => string | null | undefined,
                                  seat: (p: P) => number | null | undefined): PodSection<P>[] | null {
  const inPlay = new Set(players.map(pod).filter(Boolean));
  const shown = pods.map((p, i) => ({ p, i })).filter(({ p }) => inPlay.has(p.id));
  if (shown.length < 2) return null;
  const out: PodSection<P>[] = shown.map(({ p, i }) => ({
    pod: p.id,
    title: podTitle(p.name, i),
    items: players.map((x, k) => ({ x, k })).filter(({ x }) => pod(x) === p.id)
      .sort((a, b) => {
        const sa = seat(a.x), sb = seat(b.x);
        return Number(sa == null) - Number(sb == null) || (sa ?? 0) - (sb ?? 0) || a.k - b.k;
      })
      .map(({ x }) => x),
  }));
  const rest = players.filter((x) => !pod(x));
  if (rest.length) out.push({ pod: null, title: "Not seated", items: rest });
  return out;
}
