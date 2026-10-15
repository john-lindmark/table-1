// Draft seating and round 1 "across the table".
//
// Pods hold at most 8 drafters; bigger events split into pods of near-equal
// size (10 → 5 + 5, 17 → 6 + 6 + 5). Seats run 1..n around each table.
//
// Round 1 of a draft pairs each player with the one sitting directly across:
// in an 8-seat pod that is 1v5, 2v6, 3v7, 4v8. An odd pod gives the last seat
// the bye and pairs the rest across. Later rounds are ordinary Swiss.

export interface SeatAssignment {
  participantId: string;
  podIndex: number;
  seat: number;
}

export interface SeatedPlayer {
  participantId: string;
  podId: string | null;
  seat: number;
}

export function podSizes(count: number, maxPerPod = 8): number[] {
  if (count <= 0) return [];
  const pods = Math.ceil(count / maxPerPod);
  const base = Math.floor(count / pods);
  const extra = count % pods;
  return Array.from({ length: pods }, (_, i) => base + (i < extra ? 1 : 0));
}

export function shuffled<T>(items: T[], rng: () => number = Math.random): T[] {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

/** Random seats for an individual draft, split into pods of up to 8. */
export function seatDraft(participantIds: string[], rng: () => number = Math.random): SeatAssignment[] {
  const order = shuffled(participantIds, rng);
  const out: SeatAssignment[] = [];
  let at = 0;
  podSizes(order.length).forEach((size, podIndex) => {
    for (let s = 1; s <= size; s++) out.push({ participantId: order[at++], podIndex, seat: s });
  });
  return out;
}

/**
 * Team draft: one pod, seats alternate between the two teams in slot order
 * (A1, B1, A2, B2, ...), so every player passes to and receives from opponents.
 */
export function seatTeamDraft(teamA: string[], teamB: string[]): SeatAssignment[] {
  const out: SeatAssignment[] = [];
  const n = Math.max(teamA.length, teamB.length);
  let seat = 1;
  for (let i = 0; i < n; i++) {
    if (teamA[i]) out.push({ participantId: teamA[i], podIndex: 0, seat: seat++ });
    if (teamB[i]) out.push({ participantId: teamB[i], podIndex: 0, seat: seat++ });
  }
  return out;
}

/** Round 1 pairs for one pod, seats in table order. */
export function acrossTheTable(pod: SeatedPlayer[]): { pairs: [string, string][]; bye: string | null } {
  const bySeat = [...pod].sort((a, b) => a.seat - b.seat).map((p) => p.participantId);
  let bye: string | null = null;
  if (bySeat.length % 2 === 1) bye = bySeat.pop() ?? null;
  const half = bySeat.length / 2;
  const pairs: [string, string][] = [];
  for (let i = 0; i < half; i++) pairs.push([bySeat[i], bySeat[i + half]]);
  return { pairs, bye };
}

/** Pass direction for each pack: left, right, left. */
export function passDirection(pack: number): "left" | "right" {
  return pack % 2 === 1 ? "left" : "right";
}
