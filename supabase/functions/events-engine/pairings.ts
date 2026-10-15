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
import { acrossTheTable } from "./seating.ts";
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

/** Round 1 of a draft: across the table in every pod; byes (odd pods) go last. */
export function pairAcrossPods(active: Participant[], podOrder?: string[]): ProposedMatch[] {
  const pods = new Map<string, Participant[]>();
  for (const p of active) {
    const key = p.podId ?? "";
    pods.set(key, [...(pods.get(key) ?? []), p]);
  }
  const ordered = [...pods.entries()].sort(([a], [b]) => (podOrder?.indexOf(a) ?? 0) - (podOrder?.indexOf(b) ?? 0) || a.localeCompare(b))
    .map(([, pod]) => pod);
  const matches: ProposedMatch[] = [];
  const byes: string[] = [];
  for (const pod of ordered) {
    const { pairs, bye } = acrossTheTable(pod.map((p) => ({ participantId: p.id, podId: p.podId, seat: p.seat ?? 0 })));
    for (const [a, b] of pairs) {
      matches.push({ tableNumber: matches.length + 1, side0ParticipantId: a, side1ParticipantId: b, isBye: false });
    }
    if (bye) byes.push(bye);
  }
  for (const id of byes) {
    matches.push({ tableNumber: matches.length + 1, side0ParticipantId: id, side1ParticipantId: null, isBye: true });
  }
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
