// Swiss pairings.
//
// Round 1 is a random draw. Every later round sorts by current standings and
// pairs down the list, which is what puts players against others on the same
// match points. Rematches are avoided by exhaustive backtracking rather than a
// greedy pass, so a late round can't paint itself into a corner and hand two
// players a repeat when a valid pairing existed.
//
// The odd player out gets the bye: the lowest-ranked player who has not already
// had one. If every remaining player has had a bye, the lowest-ranked takes a
// second — that only happens in very small events.

import { computeStandings } from "./standings.ts";
import { roundOnePlan } from "./seating.ts";
import type { Participant, RoundWithMatches } from "./types.ts";

export interface ProposedMatch {
  tableNumber: number;
  side0ParticipantId: string;
  side1ParticipantId: string | null;
  isBye: boolean;
}

export interface PairRoundOptions {
  participants: Participant[];
  rounds: RoundWithMatches[];
  roundNumber: number;
  rng?: () => number;
  /** Draft events: round 1 pairs across the table within each pod (needs seats). */
  draftSeating?: boolean;
  /** Pod ids in display order, so table numbers run pod by pod. */
  podOrder?: string[];
  /**
   * Draft events, rounds 2+: "pod" pairs inside each pod (the seats odd pods leave over play each other),
   * "cross" is Swiss across every pod. Default "cross", as before pods could be picked.
   */
  podPairing?: "pod" | "cross";
}

/** Deterministic PRNG so a pairing can be reproduced in a test or an audit. */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffle<T>(items: T[], rng: () => number): T[] {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

const pairKey = (a: string, b: string) => (a < b ? `${a}|${b}` : `${b}|${a}`);

export function previousOpponents(rounds: RoundWithMatches[]): Set<string> {
  const seen = new Set<string>();
  for (const round of rounds) {
    for (const match of round.matches) {
      if (match.isBye) continue;
      const a = match.sides.find((s) => s.side === 0)?.participantId;
      const b = match.sides.find((s) => s.side === 1)?.participantId;
      if (a && b) seen.add(pairKey(a, b));
    }
  }
  return seen;
}

export function byeCounts(rounds: RoundWithMatches[]): Map<string, number> {
  const counts = new Map<string, number>();
  for (const round of rounds) {
    for (const match of round.matches) {
      if (!match.isBye) continue;
      const id = match.sides.find((s) => s.participantId)?.participantId;
      if (id) counts.set(id, (counts.get(id) ?? 0) + 1);
    }
  }
  return counts;
}

/** Exhaustive search for a rematch-free pairing of an ordered pool. */
function solve(pool: string[], played: Set<string>): [string, string][] | null {
  if (pool.length === 0) return [];
  const [first, ...rest] = pool;
  for (let i = 0; i < rest.length; i++) {
    const opponent = rest[i];
    if (played.has(pairKey(first, opponent))) continue;
    const remaining = rest.filter((_, j) => j !== i);
    const sub = solve(remaining, played);
    if (sub) return [[first, opponent], ...sub];
  }
  return null;
}

export function pairRound(options: PairRoundOptions): ProposedMatch[] {
  const { participants, rounds, roundNumber } = options;
  const rng = options.rng ?? Math.random;

  const active = participants.filter((p) => p.status === "active");
  if (active.length === 0) return [];

  if (roundNumber <= 1 && options.draftSeating && active.every((p) => p.seat != null)) {
    return pairAcrossPods(active, options.podOrder);
  }
  if (roundNumber > 1 && options.draftSeating && options.podPairing === "pod") {
    return pairInPods(active, rounds, options.podOrder);
  }

  const order =
    roundNumber <= 1
      ? shuffle(active, rng).map((p) => p.id)
      : computeStandings(active, rounds)
          .filter((s) => s.status === "active")
          .map((s) => s.participantId);

  const pool = [...order];
  const matches: ProposedMatch[] = [];

  // Odd count — hand out the bye before pairing the rest.
  let byeParticipantId: string | null = null;
  if (pool.length % 2 === 1) {
    const byes = byeCounts(rounds);
    for (let i = pool.length - 1; i >= 0; i--) {
      if ((byes.get(pool[i]) ?? 0) === 0) {
        byeParticipantId = pool[i];
        break;
      }
    }
    if (!byeParticipantId) byeParticipantId = pool[pool.length - 1];
    pool.splice(pool.indexOf(byeParticipantId), 1);
  }

  const played = previousOpponents(rounds);
  // If no rematch-free pairing exists, pair down the list anyway — an event
  // must always produce a round. A repeat is a smaller failure than a stall.
  const pairs = solve(pool, played) ?? solve(pool, new Set<string>()) ?? [];

  pairs.forEach(([a, b], i) => {
    matches.push({
      tableNumber: i + 1,
      side0ParticipantId: a,
      side1ParticipantId: b,
      isBye: false,
    });
  });

  if (byeParticipantId) {
    matches.push({
      tableNumber: matches.length + 1,
      side0ParticipantId: byeParticipantId,
      side1ParticipantId: null,
      isBye: true,
    });
  }

  return matches;
}

/** Active players grouped by pod, pods in display order (players with no pod last, as their own group). */
export function podGroups(active: Participant[], podOrder?: string[]): Participant[][] {
  const pods = new Map<string, Participant[]>();
  for (const p of active) {
    const key = p.podId ?? "";
    pods.set(key, [...(pods.get(key) ?? []), p]);
  }
  const rank = (id: string) => {
    if (id === "") return Number.MAX_SAFE_INTEGER;
    const i = podOrder?.indexOf(id) ?? -1;
    return i < 0 ? Number.MAX_SAFE_INTEGER - 1 : i;
  };
  return [...pods.entries()].sort(([a], [b]) => rank(a) - rank(b) || a.localeCompare(b)).map(([, pod]) => pod);
}

/**
 * Round 1 of a draft: across the table in every pod, then the seats odd pods leave over against each other
 * (seating.ts roundOnePlan); a bye only when the event is odd. Tables run pod by pod, the across-pod matches
 * after them, the bye last.
 */
export function pairAcrossPods(active: Participant[], podOrder?: string[]): ProposedMatch[] {
  const plan = roundOnePlan(podGroups(active, podOrder)
    .map((pod) => pod.map((p) => ({ participantId: p.id, podId: p.podId, seat: p.seat ?? 0 }))));
  const matches: ProposedMatch[] = [];
  const add = (a: string, b: string | null) =>
    matches.push({ tableNumber: matches.length + 1, side0ParticipantId: a, side1ParticipantId: b, isBye: b == null });
  for (const pod of plan.pods) for (const [a, b] of pod.pairs) add(a, b);
  for (const [a, b] of plan.across) add(a, b);
  if (plan.bye) add(plan.bye, null);
  return matches;
}

/** How many tries pairInPods makes at picking who each odd pod leaves over before it takes the best so far. */
const LEFTOVER_TRIES = 4096;

/**
 * Rounds 2+ of a draft paired inside pods (events.pod_pairing = 'pod'). Each pod pairs down its own standings
 * with no rematch where one can be avoided. An odd pod leaves one player over, picked from the bottom of the pod
 * so the rest can still pair without a rematch (a pod too small to pair without one leaves two more over); the
 * left-over players play each other across pods by overall
 * standings, and when the event is odd the lowest of them who hasn't had a bye takes it. Among the ways to pick
 * the left-over players it takes the first (lowest-ranked first) with no rematch and no second bye.
 * Tables run pod by pod, then the across-pod matches, then the bye.
 */
export function pairInPods(active: Participant[], rounds: RoundWithMatches[], podOrder?: string[]): ProposedMatch[] {
  const overall = computeStandings(active, rounds).filter((s) => s.status === "active").map((s) => s.participantId);
  const place = new Map(overall.map((id, i) => [id, i]));
  const played = previousOpponents(rounds);
  const byes = byeCounts(rounds);
  const pods = podGroups(active, podOrder)
    .map((pod) => pod.map((p) => p.id).sort((a, b) => (place.get(a) ?? 0) - (place.get(b) ?? 0)));

  // Who each pod could leave over, bottom up: an odd pod one player whose podmates still pair rematch-free; an
  // even pod nobody. A pod that can't pair that way (a pod of 2 in round 2) leaves two more over, so the rematch
  // can be avoided across pods; failing that, the plain choice.
  const choices = pods.map((ids): string[][] => {
    const bottomUp = [...ids].reverse();
    const clean = (left: string[]) => solve(ids.filter((x) => !left.includes(x)), played) != null;
    const sets = (k: number): string[][] => {
      if (k === 0) return [[]];
      const out: string[][] = [];
      const pick = (from: number, acc: string[]) => {
        if (out.length >= 24) return;
        if (acc.length === k) { out.push(acc); return; }
        for (let i = from; i < bottomUp.length; i++) pick(i + 1, [...acc, bottomUp[i]]);
      };
      pick(0, []);
      return out;
    };
    const base = ids.length % 2;
    for (let k = base; k <= Math.min(base + 2, ids.length); k += 2) {
      const ok = sets(k).filter(clean);
      if (ok.length) return ok;
    }
    return sets(base);
  });

  const leftoverPlan = (left: string[]) => {
    const pool = [...left].sort((a, b) => (place.get(a) ?? 0) - (place.get(b) ?? 0));
    let bye: string | null = null;
    if (pool.length % 2 === 1) {
      bye = [...pool].reverse().find((id) => (byes.get(id) ?? 0) === 0) ?? pool[pool.length - 1];
      pool.splice(pool.indexOf(bye), 1);
    }
    const clean = solve(pool, played);
    const pairs = clean ?? solve(pool, new Set<string>()) ?? [];
    const cost = (clean ? 0 : 2) + (bye != null && (byes.get(bye) ?? 0) > 0 ? 1 : 0);
    return { pairs, bye, cost };
  };

  let best: { pick: string[][]; plan: ReturnType<typeof leftoverPlan> } | null = null;
  let tries = 0;
  const pick: string[][] = [];
  const search = (i: number): boolean => {
    if (i === pods.length) {
      tries++;
      const plan = leftoverPlan(pick.flat());
      if (!best || plan.cost < best.plan.cost) best = { pick: [...pick], plan };
      return plan.cost === 0 || tries >= LEFTOVER_TRIES;
    }
    for (const left of choices[i]) {
      pick[i] = left;
      if (search(i + 1)) return true;
    }
    return false;
  };
  search(0);
  const chosen = best as unknown as { pick: string[][]; plan: ReturnType<typeof leftoverPlan> };

  const matches: ProposedMatch[] = [];
  const add = (a: string, b: string | null) =>
    matches.push({ tableNumber: matches.length + 1, side0ParticipantId: a, side1ParticipantId: b, isBye: b == null });
  pods.forEach((ids, i) => {
    const pool = ids.filter((id) => !chosen.pick[i].includes(id));
    const pairs = solve(pool, played) ?? solve(pool, new Set<string>()) ?? [];
    for (const [a, b] of pairs) add(a, b);
  });
  for (const [a, b] of chosen.plan.pairs) add(a, b);
  if (chosen.plan.bye) add(chosen.plan.bye, null);
  return matches;
}

/**
 * Conventional Swiss round counts. The MTR's Appendix E table did not survive
 * PDF extraction, so these are the widely used values — confirm against the
 * current document before running anything sanctioned.
 */
export function recommendedRounds(playerCount: number): number {
  if (playerCount <= 2) return 1;
  if (playerCount <= 4) return 2;
  if (playerCount <= 8) return 3;
  if (playerCount <= 16) return 4;
  if (playerCount <= 32) return 5;
  if (playerCount <= 64) return 6;
  if (playerCount <= 128) return 7;
  return 8;
}

/** Random seat order for a draft pod, 1..n. */
export function assignSeats(participantIds: string[], rng: () => number = Math.random): Map<string, number> {
  const shuffled = shuffle(participantIds, rng);
  return new Map(shuffled.map((id, i) => [id, i + 1]));
}
