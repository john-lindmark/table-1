// Top 8 after Swiss, automatic Swiss rounds and the organizer's next step
// (contract/scheduled-events-2026-10-27.md §5–6; shared cases testdata/scheduled-events/cases.json).
//
//   Seeds          the Swiss standings of active players; quarterfinals 1v8, 4v5, 2v7, 3v6 on tables 1–4
//   Semifinals     winner(T1) v winner(T2), winner(T3) v winner(T4); the final is the two semifinal winners
//   Side 0         the higher seed (they choose to play or draw)
//   Final order    winner, finalist, semifinal losers, quarterfinal losers (each by seed), then the rest by Swiss
//
// Once the quarterfinals are paired, seeds are read back from their tables, so a later drop never reshuffles them.

import { computeStandings, type Standing } from "./standings.ts";
import type { ProposedMatch } from "./pairings.ts";
import type { Match, Participant, RoundWithMatches } from "./types.ts";

export type Stage = "swiss" | "quarterfinal" | "semifinal" | "final";
export type Playoff = "winner" | "final" | "semifinal" | "quarterfinal";
export type StagedRound = RoundWithMatches & { stage?: Stage | null };
export type NextStep = "start" | "waiting" | "pair" | "cut" | "semifinals" | "final" | "finish";

export const stageOf = (r: { stage?: Stage | null }): Stage => r.stage ?? "swiss";
const isSwiss = (r: { stage?: Stage | null }) => stageOf(r) === "swiss";

/** Swiss rounds for a number of players (t1_private.swiss_rounds; above 128 the MTR Appendix E bands). */
export function swissRounds(players: number): number {
  const bands: [number, number][] = [[2, 1], [4, 2], [8, 3], [16, 4], [32, 5], [64, 6], [128, 7], [226, 8], [409, 9]];
  for (const [max, rounds] of bands) if (players <= max) return rounds;
  return 10;
}

/**
 * Automatic Swiss rounds for a draft with pods (contract/draft-pods-2026-11-09.md): paired inside pods, enough
 * for the largest pod (two pods of 8 play 3); across pods, enough for everyone (16 play 4).
 */
export function draftRounds(podSizes: number[], podPairing: "pod" | "cross"): number {
  const sizes = podSizes.filter((n) => n > 0);
  if (sizes.length === 0) return swissRounds(0);
  return podPairing === "pod" ? swissRounds(Math.max(...sizes)) : swissRounds(sizes.reduce((a, b) => a + b, 0));
}

/**
 * What the organizer does next. `stages` are the paired rounds in order; `waiting` is true while the open round
 * still has a match without a result or with a dispute.
 */
export function nextStep(input: {
  stages: Stage[]; waiting: boolean; numberOfRounds: number; topCut: number; activePlayers: number;
}): NextStep {
  const { stages, waiting, numberOfRounds, topCut, activePlayers } = input;
  if (stages.length === 0) return "start";
  if (waiting) return "waiting";
  const last = stages[stages.length - 1];
  if (last === "swiss") {
    if (stages.filter((s) => s === "swiss").length < numberOfRounds) return "pair";
    return topCut === 8 && activePlayers > 8 ? "cut" : "finish";
  }
  return last === "quarterfinal" ? "semifinals" : last === "semifinal" ? "final" : "finish";
}

/** The stage pair_round opens next, or null when every round is played. */
export function nextStage(rounds: StagedRound[], numberOfRounds: number, topCut: number, activePlayers: number): Stage | null {
  const step = nextStep({ stages: rounds.map(stageOf), waiting: false, numberOfRounds, topCut, activePlayers });
  return step === "start" || step === "pair" ? "swiss"
    : step === "cut" ? "quarterfinal" : step === "semifinals" ? "semifinal" : step === "final" ? "final" : null;
}

/** The side that won a scored playoff match, or null. */
export function matchWinner(m: Match): string | null {
  if (m.isBye || m.status === "pending") return null;
  const a = m.sides.find((s) => s.side === 0), b = m.sides.find((s) => s.side === 1);
  if (!a?.participantId || !b?.participantId || a.gameWins === b.gameWins) return null;
  return a.gameWins > b.gameWins ? a.participantId : b.participantId;
}

const QUARTERS: [number, number][] = [[1, 8], [4, 5], [2, 7], [3, 6]];

/** Seed per participant: from the quarterfinal tables once paired, else the top 8 active Swiss players. */
export function seeds(participants: Participant[], rounds: StagedRound[]): Map<string, number> {
  const out = new Map<string, number>();
  const quarters = rounds.find((r) => stageOf(r) === "quarterfinal");
  if (quarters) {
    for (const m of quarters.matches) {
      const pair = QUARTERS[(m.tableNumber ?? 0) - 1];
      if (!pair) continue;
      for (const s of m.sides) if (s.participantId) out.set(s.participantId, pair[s.side]);
    }
    return out;
  }
  computeStandings(participants, rounds.filter(isSwiss))
    .filter((s) => s.status === "active").slice(0, 8)
    .forEach((s, i) => out.set(s.participantId, i + 1));
  return out;
}

/** Pairings for a playoff stage. Throws when the stage before it isn't finished. */
export function pairPlayoff(stage: Exclude<Stage, "swiss">, participants: Participant[], rounds: StagedRound[]): ProposedMatch[] {
  const seed = seeds(participants, rounds);
  const bySeed = new Map([...seed].map(([id, n]) => [n, id]));
  const table = (pairs: [string, string][]): ProposedMatch[] =>
    pairs.map(([x, y], i) => {
      const [hi, lo] = (seed.get(x) ?? 99) <= (seed.get(y) ?? 99) ? [x, y] : [y, x];
      return { tableNumber: i + 1, isBye: false, side0ParticipantId: hi, side1ParticipantId: lo };
    });
  if (stage === "quarterfinal") {
    if (bySeed.size < 8) throw new Error("Top 8 needs 9 or more players");
    return table(QUARTERS.map(([x, y]) => [bySeed.get(x)!, bySeed.get(y)!]));
  }
  const before = rounds.find((r) => stageOf(r) === (stage === "semifinal" ? "quarterfinal" : "semifinal"));
  const winners = (before?.matches ?? [])
    .slice().sort((x, y) => (x.tableNumber ?? 0) - (y.tableNumber ?? 0)).map(matchWinner);
  const need = stage === "semifinal" ? 4 : 2;
  if (winners.length !== need || winners.some((w) => !w)) throw new Error("Every playoff match needs a winner first");
  const w = winners as string[];
  return table(stage === "semifinal" ? [[w[0], w[1]], [w[2], w[3]]] : [[w[0], w[1]]]);
}

export interface PlayoffStanding extends Standing {
  swissRank: number;
  playoff: Playoff | null;
}

const ORDER: Record<Playoff, number> = { winner: 0, final: 1, semifinal: 2, quarterfinal: 3 };

/** Final order: Swiss standings, with the top 8 placed by how far they went once the cut is made. */
export function playoffStandings(participants: Participant[], rounds: StagedRound[]): PlayoffStanding[] {
  const swiss = computeStandings(participants, rounds.filter(isSwiss));
  const playoffRounds = rounds.filter((r) => !isSwiss(r));
  const reached = new Map<string, Playoff>();
  for (const r of playoffRounds) {
    for (const m of r.matches) {
      for (const s of m.sides) if (s.participantId) reached.set(s.participantId, stageOf(r) as Playoff);
      if (stageOf(r) === "final") {
        const w = matchWinner(m);
        if (w) reached.set(w, "winner");
      }
    }
  }
  const seed = playoffRounds.length ? seeds(participants, rounds) : new Map<string, number>();
  const rows: PlayoffStanding[] = swiss.map((s) => ({ ...s, swissRank: s.rank, playoff: reached.get(s.participantId) ?? null }));
  rows.sort((x, y) => {
    if (x.playoff && y.playoff) {
      return ORDER[x.playoff] - ORDER[y.playoff] || (seed.get(x.participantId) ?? 99) - (seed.get(y.participantId) ?? 99);
    }
    if (x.playoff || y.playoff) return x.playoff ? -1 : 1;
    return x.swissRank - y.swissRank;
  });
  rows.forEach((r, i) => (r.rank = i + 1));
  return rows;
}

export interface BracketStage {
  stage: Exclude<Stage, "swiss">;
  matches: {
    match_id: string; table_number: number | null; status: Match["status"]; winner: string | null;
    sides: { seed: number | null; participant_id: string | null; display_name: string | null; game_wins: number }[];
  }[];
}

/** The playoff rounds paired so far, for drawing the bracket. */
export function bracket(participants: Participant[], rounds: StagedRound[]): BracketStage[] {
  const playoffRounds = rounds.filter((r) => !isSwiss(r));
  if (!playoffRounds.length) return [];
  const seed = seeds(participants, rounds);
  const name = new Map(participants.map((p) => [p.id, p.displayName]));
  return playoffRounds.map((r) => ({
    stage: stageOf(r) as Exclude<Stage, "swiss">,
    matches: r.matches.slice().sort((x, y) => (x.tableNumber ?? 0) - (y.tableNumber ?? 0)).map((m) => ({
      match_id: m.id, table_number: m.tableNumber, status: m.status, winner: matchWinner(m),
      sides: m.sides.slice().sort((x, y) => x.side - y.side).map((s) => ({
        seed: s.participantId ? seed.get(s.participantId) ?? null : null, participant_id: s.participantId,
        display_name: s.participantId ? name.get(s.participantId) ?? null : null, game_wins: s.gameWins,
      })),
    })),
  }));
}
