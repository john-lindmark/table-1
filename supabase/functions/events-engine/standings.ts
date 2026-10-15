// Standings and tiebreakers, per the Magic Tournament Rules (Feb 27 2026).
//
//   Match points   win 3 · draw 1 · loss 0 · bye 3
//   Game points    game win 3 · game draw 1 · game loss 0
//   MWP            match points / (3 x matches played), floored at 0.33
//   GWP            game points  / (3 x games played),   floored at 0.33
//   OMW%           mean of each opponent's MWP — byes contribute no opponent
//   OGW%           mean of each opponent's GWP — byes contribute no opponent
//   Order          match points, then OMW%, then GWP, then OGW%
//
// A bye counts as a 2-0 match win for the player's own game-win percentage.
// Dropped players keep counting toward their opponents' tiebreakers; that is
// the point of the tiebreaker, and removing them would rewrite history.

import type { Match, Participant, RoundWithMatches } from "./types.ts";

export const MIN_PERCENTAGE = 1 / 3;

export interface PlayerRecord {
  participantId: string;
  matchWins: number;
  matchLosses: number;
  matchDraws: number;
  byes: number;
  matchPoints: number;
  matchesPlayed: number;
  gamePoints: number;
  gamesPlayed: number;
  opponentIds: string[];
}

export interface Standing extends PlayerRecord {
  rank: number;
  displayName: string;
  status: Participant["status"];
  matchWinPct: number;
  gameWinPct: number;
  opponentMatchWinPct: number;
  opponentGameWinPct: number;
}

function emptyRecord(participantId: string): PlayerRecord {
  return {
    participantId,
    matchWins: 0,
    matchLosses: 0,
    matchDraws: 0,
    byes: 0,
    matchPoints: 0,
    matchesPlayed: 0,
    gamePoints: 0,
    gamesPlayed: 0,
    opponentIds: [],
  };
}

/** A match only counts once someone has actually reported it. */
export function isMatchScored(match: Match): boolean {
  return match.isBye || match.status === "reported" || match.status === "confirmed";
}

export function buildRecords(
  participants: Participant[],
  rounds: RoundWithMatches[],
): Map<string, PlayerRecord> {
  const records = new Map<string, PlayerRecord>();
  for (const p of participants) records.set(p.id, emptyRecord(p.id));

  for (const round of rounds) {
    for (const match of round.matches) {
      if (!isMatchScored(match)) continue;

      if (match.isBye) {
        const side = match.sides.find((s) => s.participantId);
        if (!side?.participantId) continue;
        const rec = records.get(side.participantId);
        if (!rec) continue;
        rec.byes += 1;
        rec.matchWins += 1;
        rec.matchPoints += 3;
        rec.matchesPlayed += 1;
        // A bye is scored as a 2-0 win for game-win percentage.
        rec.gamePoints += 6;
        rec.gamesPlayed += 2;
        continue;
      }

      const a = match.sides.find((s) => s.side === 0);
      const b = match.sides.find((s) => s.side === 1);
      if (!a?.participantId || !b?.participantId) continue;
      const recA = records.get(a.participantId);
      const recB = records.get(b.participantId);
      if (!recA || !recB) continue;

      const draws = match.gameDraws ?? 0;
      const games = a.gameWins + b.gameWins + draws;

      recA.matchesPlayed += 1;
      recB.matchesPlayed += 1;
      recA.opponentIds.push(b.participantId);
      recB.opponentIds.push(a.participantId);

      recA.gamePoints += a.gameWins * 3 + draws;
      recB.gamePoints += b.gameWins * 3 + draws;
      recA.gamesPlayed += games;
      recB.gamesPlayed += games;

      if (a.gameWins > b.gameWins) {
        recA.matchWins += 1;
        recA.matchPoints += 3;
        recB.matchLosses += 1;
      } else if (b.gameWins > a.gameWins) {
        recB.matchWins += 1;
        recB.matchPoints += 3;
        recA.matchLosses += 1;
      } else {
        recA.matchDraws += 1;
        recB.matchDraws += 1;
        recA.matchPoints += 1;
        recB.matchPoints += 1;
      }
    }
  }
  return records;
}

export function matchWinPct(rec: PlayerRecord): number {
  if (rec.matchesPlayed === 0) return MIN_PERCENTAGE;
  return Math.max(MIN_PERCENTAGE, rec.matchPoints / (3 * rec.matchesPlayed));
}

export function gameWinPct(rec: PlayerRecord): number {
  if (rec.gamesPlayed === 0) return MIN_PERCENTAGE;
  return Math.max(MIN_PERCENTAGE, rec.gamePoints / (3 * rec.gamesPlayed));
}

function averageOverOpponents(
  opponentIds: string[],
  records: Map<string, PlayerRecord>,
  pct: (rec: PlayerRecord) => number,
): number {
  if (opponentIds.length === 0) return MIN_PERCENTAGE;
  let sum = 0;
  for (const id of opponentIds) {
    const rec = records.get(id);
    sum += rec ? pct(rec) : MIN_PERCENTAGE;
  }
  return sum / opponentIds.length;
}

export function computeStandings(
  participants: Participant[],
  rounds: RoundWithMatches[],
): Standing[] {
  const records = buildRecords(participants, rounds);
  const byId = new Map(participants.map((p) => [p.id, p]));

  const rows = participants.map((p) => {
    const rec = records.get(p.id) ?? emptyRecord(p.id);
    return {
      ...rec,
      rank: 0,
      displayName: byId.get(p.id)?.displayName ?? "—",
      status: p.status,
      matchWinPct: matchWinPct(rec),
      gameWinPct: gameWinPct(rec),
      opponentMatchWinPct: averageOverOpponents(rec.opponentIds, records, matchWinPct),
      opponentGameWinPct: averageOverOpponents(rec.opponentIds, records, gameWinPct),
    } satisfies Standing;
  });

  rows.sort((x, y) => {
    if (y.matchPoints !== x.matchPoints) return y.matchPoints - x.matchPoints;
    if (y.opponentMatchWinPct !== x.opponentMatchWinPct)
      return y.opponentMatchWinPct - x.opponentMatchWinPct;
    if (y.gameWinPct !== x.gameWinPct) return y.gameWinPct - x.gameWinPct;
    if (y.opponentGameWinPct !== x.opponentGameWinPct)
      return y.opponentGameWinPct - x.opponentGameWinPct;
    // Deterministic last resort so the same data always renders the same order.
    return x.displayName.localeCompare(y.displayName);
  });

  rows.forEach((row, i) => (row.rank = i + 1));
  return rows;
}

export function formatPct(value: number): string {
  return `${(value * 100).toFixed(1)}%`;
}

export function recordLabel(rec: PlayerRecord): string {
  return rec.matchDraws > 0
    ? `${rec.matchWins}-${rec.matchLosses}-${rec.matchDraws}`
    : `${rec.matchWins}-${rec.matchLosses}`;
}
