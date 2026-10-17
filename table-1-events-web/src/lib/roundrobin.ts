// Round robin: everyone plays everyone once (roto events; plan-roto-2026-10-15.md).
//
// The circle method over the seat order: seat 1 stays put, everyone else rotates one place each round, and round r
// pairs the k-th from the front with the k-th from the back. An odd roster gets a phantom seat, and whoever meets
// it has the bye. The schedule depends only on the roster and the round number, so pairing a round twice (or after
// an undo) always gives the same tables. It matches t1_private.demo_round, so demo events continue cleanly.
//
// The roster is fixed at round 1: everyone seated who was still in the event then. A player who drops later keeps
// their place in the schedule, and each opponent they would have met gets a bye instead (2–0, 3 points).

import type { ProposedMatch } from "./pairings";
import type { Participant } from "./types";

/** Players in the schedule, by seat: seated, and active or dropped after round 1 started. */
export function roundRobinRoster(participants: Participant[]): Participant[] {
  return participants
    .filter((p) => p.seat != null && (p.status === "active" || (p.droppedInRound ?? 0) >= 1))
    .sort((a, b) => (a.seat ?? 0) - (b.seat ?? 0));
}

/** Rounds needed: n − 1 for an even roster, n for an odd one (each player sits out once). */
export function roundRobinRounds(rosterSize: number): number {
  if (rosterSize < 2) return 0;
  return rosterSize % 2 === 0 ? rosterSize - 1 : rosterSize;
}

/** Pairs of roster ids for round r (1-based); null is the phantom seat. */
export function roundRobinPairs(ids: string[], round: number): [string | null, string | null][] {
  const seats: (string | null)[] = ids.length % 2 === 0 ? [...ids] : [...ids, null];
  const n = seats.length;
  if (n < 2) return [];
  const rot = [seats[0], ...Array.from({ length: n - 1 }, (_, g) => seats[1 + ((g + round - 1) % (n - 1))])];
  return Array.from({ length: n / 2 }, (_, k) => [rot[k], rot[n - 1 - k]] as [string | null, string | null]);
}

/** Round r's matches: real tables first, then byes (phantom seat or a dropped opponent). */
export function pairRoundRobin(participants: Participant[], round: number): ProposedMatch[] {
  const roster = roundRobinRoster(participants);
  const active = new Set(roster.filter((p) => p.status === "active").map((p) => p.id));
  const matches: ProposedMatch[] = [];
  const byes: string[] = [];
  for (const [a, b] of roundRobinPairs(roster.map((p) => p.id), round)) {
    const aIn = a != null && active.has(a);
    const bIn = b != null && active.has(b);
    if (aIn && bIn) {
      matches.push({ tableNumber: matches.length + 1, side0ParticipantId: a!, side1ParticipantId: b!, isBye: false });
    } else if (aIn) {
      byes.push(a!);
    } else if (bIn) {
      byes.push(b!);
    }
  }
  for (const id of byes) {
    matches.push({ tableNumber: matches.length + 1, side0ParticipantId: id, side1ParticipantId: null, isBye: true });
  }
  return matches;
}
