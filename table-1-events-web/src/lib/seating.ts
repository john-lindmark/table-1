// Draft seating and round 1 "across the table".
//
// Pods hold at most 8 drafters; bigger events split into pods of near-equal
// size (10 → 5 + 5, 17 → 6 + 6 + 5). Seats run 1..n around each table.
//
// Round 1 of a draft pairs each player with the one sitting directly across:
// in an 8-seat pod that is 1v5, 2v6, 3v7, 4v8. An odd pod's last seat is left
// over: the left-over seats of odd pods play each other (pod 1's against pod
// 2's, pod 3's against pod 4's), and only an odd total leaves the last one a
// bye. Later rounds stay inside each pod ("pod") or are Swiss across every pod
// ("cross"), events.pod_pairing (contract/draft-pods-2026-11-09.md).

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

/**
 * How many pods an organizer's pick makes: `pods` null is automatic (pods of up to 8), otherwise that many,
 * never so many that a pod would hold fewer than 2 (t1_private.pod_count says the same).
 */
export function podCount(players: number, pods: number | null | undefined): number {
  if (players <= 0) return 0;
  if (pods == null) return Math.ceil(players / 8);
  return Math.max(1, Math.min(Math.floor(pods), Math.floor(players / 2)));
}

/** Pod sizes for the organizer's pick, largest first: 14 players in 2 → [7, 7]; 17 automatic → [6, 6, 5]. */
export function podPlan(players: number, pods: number | null | undefined): number[] {
  const count = podCount(players, pods);
  if (count === 0) return [];
  const base = Math.floor(players / count);
  const extra = players % count;
  return Array.from({ length: count }, (_, i) => base + (i < extra ? 1 : 0));
}

/** A pick summed up before the draw: "2 pods · 9, 8", "1 pod · 6", "No players yet" (testdata/draft-pods). */
export function podLabel(players: number, pods: number | null | undefined): string {
  const sizes = podPlan(players, pods);
  if (sizes.length === 0) return "No players yet";
  if (sizes.length === 1) return `1 pod · ${sizes[0]}`;
  return `${sizes.length} pods · ${sizes.join(", ")}`;
}

export function shuffled<T>(items: T[], rng: () => number = Math.random): T[] {
  const out = [...items];
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

/** Random seats for an individual draft, split into pods of up to 8 (or the organizer's number of pods). */
export function seatDraft(participantIds: string[], rng: () => number = Math.random, pods: number | null = null): SeatAssignment[] {
  const order = shuffled(participantIds, rng);
  const out: SeatAssignment[] = [];
  let at = 0;
  podPlan(order.length, pods).forEach((size, podIndex) => {
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

/**
 * Round 1 across every pod: each pod across its table, then the seats odd pods leave over paired in pod order
 * (1st v 2nd, 3rd v 4th, …), the last one a bye when the event is odd. `pods` in display order.
 */
export function roundOnePlan(pods: SeatedPlayer[][]): {
  pods: { pairs: [string, string][]; left: string | null }[]; across: [string, string][]; bye: string | null;
} {
  const out = pods.map((pod) => {
    const { pairs, bye } = acrossTheTable(pod);
    return { pairs, left: bye };
  });
  const left = out.map((p) => p.left).filter((id): id is string => id != null);
  const across: [string, string][] = [];
  for (let i = 0; i + 1 < left.length; i += 2) across.push([left[i], left[i + 1]]);
  return { pods: out, across, bye: left.length % 2 === 1 ? left[left.length - 1] : null };
}

/** Pass direction for each pack: left, right, left. */
export function passDirection(pack: number): "left" | "right" {
  return pack % 2 === 1 ? "left" : "right";
}
