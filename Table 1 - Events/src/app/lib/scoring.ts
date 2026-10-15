import type { EventState, Pairing, Player } from "./types";

export interface TeamScore {
  recorded: number;
  pending: number;
  total: number;
}

// Result of resolving a single individual matchup. `winner` is the pairing side
// ("a" = team A player, "b" = team B player) that receives the matchup win.
// A `draw` has no winner and is never counted as a win for either team.
export type MatchupStatus =
  | "not_started"
  | "decisive"
  | "draw"
  | "invalid";

export type ResolutionMethod = "game_score" | null;

export interface PairingResolution {
  status: MatchupStatus;
  winner: "a" | "b" | null;
  method: ResolutionMethod;
}

function gw(p: Pairing): { a: number; b: number } {
  return { a: p.teamAGameWins ?? 0, b: p.teamBGameWins ?? 0 };
}

// Resolve a single pairing purely from its game score:
//   0-0            → not_started (no result entered yet)
//   equal & > 0-0  → draw (1-1) — counts as a draw, never a win
//   unequal valid  → decisive, winner by game score
//   2-2 or > 2     → invalid (blocks recording)
// Ties are NOT awarded to either team; there is no format-record or organizer
// tie-breaking any more.
function resolvePairing(p: Pairing): PairingResolution {
  const { a, b } = gw(p);
  if (a > 2 || b > 2 || (a === 2 && b === 2)) {
    return { status: "invalid", winner: null, method: null };
  }
  if (a === 0 && b === 0) {
    return { status: "not_started", winner: null, method: null };
  }
  if (a === b) {
    return { status: "draw", winner: null, method: null };
  }
  return { status: "decisive", winner: a > b ? "a" : "b", method: "game_score" };
}

function playerTeamLookup(players: Player[]): (playerId: string) => string {
  const map = new Map(players.map((p) => [p.id, p.teamId]));
  return (id: string) => map.get(id) ?? "";
}

// Resolve a whole round's pairings (all formats).
export function resolvePairings(
  pairings: Pairing[],
  _players: Player[],
): Record<string, PairingResolution> {
  const out: Record<string, PairingResolution> = {};
  for (const p of pairings) out[p.id] = resolvePairing(p);
  return out;
}

// Convenience resolution for the current (in-progress) round.
export function resolveCurrent(event: EventState): Record<string, PairingResolution> {
  return resolvePairings(event.currentPairings, event.players);
}

// Count matchup wins per team id across a set of pairings. Draws are excluded.
function countWins(
  pairings: Pairing[],
  players: Player[],
): Record<string, number> {
  const playerTeam = playerTeamLookup(players);
  const counts: Record<string, number> = {};
  for (const p of pairings) {
    const winner = resolvePairing(p).winner;
    if (!winner) continue;
    const team = playerTeam(winner === "a" ? p.teamAPlayerId : p.teamBPlayerId);
    counts[team] = (counts[team] ?? 0) + 1;
  }
  return counts;
}

// Number of drawn matchups in a set of pairings (neutral — not per team).
export function countDraws(pairings: Pairing[]): number {
  return pairings.reduce((n, p) => (resolvePairing(p).status === "draw" ? n + 1 : n), 0);
}

// The Total Recorded Match Wins bar counts matchup wins (one per decided
// pairing), not game wins. Draws contribute to neither side.
export function computeScores(event: EventState): Record<string, TeamScore> {
  const result: Record<string, TeamScore> = {};

  const recordedCounts: Record<string, number> = {};
  for (const round of event.recordedRounds) {
    const c = countWins(round.pairings, event.players);
    for (const [team, n] of Object.entries(c)) {
      recordedCounts[team] = (recordedCounts[team] ?? 0) + n;
    }
  }

  // Only count the current round as "pending" when it has NOT already been
  // recorded. For a completed event the final round appears in both
  // recordedRounds and currentPairings, so counting both double-counts it.
  const recordedRoundNumbers = new Set(event.recordedRounds.map((r) => r.roundNumber));
  const includePending = !recordedRoundNumbers.has(event.currentRoundNumber);
  const pendingCounts = includePending ? countWins(event.currentPairings, event.players) : {};

  for (const team of event.teams) {
    const recorded = recordedCounts[team.id] ?? 0;
    const pending = pendingCounts[team.id] ?? 0;
    result[team.id] = { recorded, pending, total: recorded + pending };
  }
  return result;
}

// Per-round matchup-win totals keyed by team id (used for round summaries).
export function roundWinsByTeam(pairings: Pairing[], players: Player[]) {
  return countWins(pairings, players);
}

// A round is ready to record when every pairing has an entered result — either
// a decisive game score or a draw — and none is invalid (2-2).
export function allResultsEntered(event: EventState): boolean {
  const res = resolveCurrent(event);
  return event.currentPairings.every((p) => {
    const r = res[p.id];
    return r && (r.status === "decisive" || r.status === "draw");
  });
}

// Any 2-2 present blocks recording and should be flagged distinctly.
export function hasInvalidPairing(event: EventState): boolean {
  const res = resolveCurrent(event);
  return event.currentPairings.some((p) => res[p.id]?.status === "invalid");
}

export function resultsEnteredForFormat(event: EventState, formatId: string) {
  const res = resolveCurrent(event);
  const pairings = event.currentPairings.filter((p) => p.formatId === formatId);
  const entered = pairings.filter((p) => {
    const r = res[p.id];
    return r && (r.status === "decisive" || r.status === "draw");
  }).length;
  return { entered, total: pairings.length };
}
