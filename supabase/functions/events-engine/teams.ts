// Team events (teams of 3 or 4).
//
// Individual matches are still ordinary matches: they feed each player's own
// standings, lifetime record and head-to-head. On top of that, the members of
// two teams who meet in a round form a *team match*:
//
//   team result   the team whose members won more of those matches takes it;
//                 equal is a team draw (e.g. 2–2 with teams of 4)
//   team points   win 3 · draw 1 · loss 0 · team bye 3
//   order         team points, then members' total match wins, then the
//                 team's game-win %, then name
//   members       listed best first by their own record: match points, then
//                 game-win % (2-0 2-1 2-1 above 2-1 2-1 2-1), then OMW%, then
//                 OGW%, then seat letter
//   clinched      two teams head to head: one has clinched once the other
//                 can't catch its match wins with every match still to play
//                 (5 of 9 in a 3v3 over three rounds, 7 of 12 in a 4v4); the
//                 organizer may then finish without the rest (teamClinch)
//
// A member whose opponent dropped gets a bye, which counts as a match win for
// their team. A team match only counts once every one of its matches is in.
//
// Team draft: exactly two teams in one pod; each round every player meets a
// different member of the other team (A_i plays B_(i+round) mod size), which
// in alternating seats puts round 1 across the table.
// Team sealed and Team Trios (team_trios: three seats, a constructed format
// each): Swiss between teams; seat A plays seat A, B plays B, and so on.
//
// A team a player short. Team sealed: its remaining players move up (with
// seat B gone, seat C plays the other team's seat B) and the other team's
// last seat has the bye. Team Trios: seats never move, since each seat is a
// format: seat C still plays seat C, and the dropped seat's opponent has the
// bye. Either way the bye is a match win for its team.
//
// Top 4 (team sealed and Team Trios with top_cut 4; never a team draft, never
// a top 8). After the Swiss rounds, with 5 or more active teams:
//
//   seeds        the Swiss team standings of active teams (a team is active
//                while it has an active member, as in the Swiss rounds)
//   semifinals   seed 1 v 4, then 2 v 3; the final is the two winners
//   team match   one match per seat, slot against slot, in a round whose stage
//                is semifinal / final; the higher seed's players are side 0
//   winner       the team that wins more of those matches (a bye counts for
//                its team); level, e.g. 2–2 with teams of 4: the higher seed
//   final order  winner, finalist, the losing semifinalists by seed, then
//                everyone else by Swiss team standing
//
// Once the semifinals are paired, seeds are read back from their tables, so a
// later drop never reshuffles them. Team points, records and tiebreakers are
// Swiss only: playoff rounds decide the order, not the numbers.

import { buildRecords, computeStandings, isMatchScored } from "./standings.ts";
import { nextStage, SEMIS, stageOf, type Playoff, type Stage, type StagedRound } from "./playoffs.ts";
import type { ProposedMatch } from "./pairings.ts";
import type { Match, Participant, RoundWithMatches } from "./types.ts";

export interface Team {
  id: string;
  name: string;
  order: number;
}

export type TeamRoundResult = "win" | "loss" | "draw" | "bye" | "pending";

export interface TeamStanding {
  teamId: string;
  name: string;
  rank: number;
  points: number;
  wins: number;
  losses: number;
  draws: number;
  byes: number;
  /** Individual match wins across the team's members, byes included. */
  matchWins: number;
  gameWinPct: number;
  opponentTeamIds: string[];
  /** Best first by their own record (see the header). */
  members: {
    participantId: string; displayName: string; slot: number | null; matchWins: number; matchLosses: number;
    matchDraws: number; status: Participant["status"];
  }[];
}

/** A team's row once playoffs may count: `rank` is the final order after the top 4 is cut, the Swiss standing until then. */
export interface TeamPlayoffStanding extends TeamStanding {
  swissRank: number;
  /** The furthest playoff stage reached (top 4), or null. */
  playoff: Playoff | null;
}

const MIN_PCT = 1 / 3;

/** Team formats paired as Swiss between teams, slot against slot. */
export const isTeamSwiss = (format: string | null | undefined) => format === "team_sealed" || format === "team_trios";
/** Every team format: team draft (two teams), team sealed, Team Trios. */
export const isTeamEvent = (format: string | null | undefined) => format === "team_draft" || isTeamSwiss(format);
/** Team Trios: a seat is a format, so seat A only ever plays seat A, whoever has dropped. */
export const pairsBySeat = (format: string | null | undefined) => format === "team_trios";

const isSwissRound = (r: RoundWithMatches) => stageOf(r as StagedRound) === "swiss";

export function membersOf(teamId: string, participants: Participant[], activeOnly = true): Participant[] {
  return participants
    .filter((p) => p.teamId === teamId && (!activeOnly || p.status === "active"))
    .sort((a, b) => (a.teamSlot ?? 99) - (b.teamSlot ?? 99) || a.displayName.localeCompare(b.displayName));
}

/** Each team's result in each round, keyed by round number then team id. */
export function teamRoundResults(
  teams: Team[],
  participants: Participant[],
  rounds: RoundWithMatches[],
): Map<number, Map<string, { result: TeamRoundResult; opponent: string | null; won: number; lost: number }>> {
  const teamOf = new Map(participants.map((p) => [p.id, p.teamId ?? null]));
  const out = new Map<number, Map<string, { result: TeamRoundResult; opponent: string | null; won: number; lost: number }>>();
  for (const round of rounds) {
    const perTeam = new Map<string, { opponent: string | null; won: number; lost: number; pending: boolean; byes: number; played: number }>();
    const entry = (t: string) => {
      let e = perTeam.get(t);
      if (!e) perTeam.set(t, (e = { opponent: null, won: 0, lost: 0, pending: false, byes: 0, played: 0 }));
      return e;
    };
    for (const match of round.matches) {
      if (match.isBye) {
        const pid = match.sides.find((s) => s.participantId)?.participantId;
        const t = pid ? teamOf.get(pid) : null;
        if (t) entry(t).byes += 1;
        continue;
      }
      const a = match.sides.find((s) => s.side === 0);
      const b = match.sides.find((s) => s.side === 1);
      const ta = a?.participantId ? teamOf.get(a.participantId) : null;
      const tb = b?.participantId ? teamOf.get(b.participantId) : null;
      if (!ta || !tb || ta === tb || !a || !b) continue;
      const ea = entry(ta);
      const eb = entry(tb);
      ea.opponent = tb;
      eb.opponent = ta;
      ea.played += 1;
      eb.played += 1;
      if (!isMatchScored(match)) {
        ea.pending = eb.pending = true;
        continue;
      }
      if (a.gameWins > b.gameWins) {
        ea.won += 1;
        eb.lost += 1;
      } else if (b.gameWins > a.gameWins) {
        eb.won += 1;
        ea.lost += 1;
      }
    }
    const results = new Map<string, { result: TeamRoundResult; opponent: string | null; won: number; lost: number }>();
    for (const team of teams) {
      const e = perTeam.get(team.id);
      if (!e) continue;
      if (e.played === 0) {
        if (e.byes > 0) results.set(team.id, { result: "bye", opponent: null, won: e.byes, lost: 0 });
        continue;
      }
      const won = e.won + e.byes;
      const result: TeamRoundResult = e.pending ? "pending" : won > e.lost ? "win" : won < e.lost ? "loss" : "draw";
      results.set(team.id, { result, opponent: e.opponent, won, lost: e.lost });
    }
    out.set(round.number, results);
  }
  return out;
}

/** Swiss standings between teams. Playoff rounds never count here. */
export function teamSwissStandings(
  teams: Team[],
  participants: Participant[],
  allRounds: RoundWithMatches[],
): TeamStanding[] {
  const rounds = allRounds.filter(isSwissRound);
  const records = buildRecords(participants, rounds);
  const perRound = teamRoundResults(teams, participants, rounds);
  const individual = new Map(computeStandings(participants, rounds).map((s) => [s.participantId, s]));
  const byRecord = (a: Participant, b: Participant) => {
    const x = individual.get(a.id);
    const y = individual.get(b.id);
    if (!x || !y) return (x ? 0 : 1) - (y ? 0 : 1);
    return y.matchPoints - x.matchPoints || y.gameWinPct - x.gameWinPct ||
      y.opponentMatchWinPct - x.opponentMatchWinPct || y.opponentGameWinPct - x.opponentGameWinPct ||
      (a.teamSlot ?? 99) - (b.teamSlot ?? 99);
  };
  const rows: TeamStanding[] = teams.map((team) => {
    const members = membersOf(team.id, participants, false).sort(byRecord);
    let points = 0, wins = 0, losses = 0, draws = 0, byes = 0;
    const opponents: string[] = [];
    for (const results of perRound.values()) {
      const r = results.get(team.id);
      if (!r) continue;
      if (r.result === "win") { points += 3; wins += 1; }
      else if (r.result === "draw") { points += 1; draws += 1; }
      else if (r.result === "loss") losses += 1;
      else if (r.result === "bye") { points += 3; byes += 1; }
      if (r.opponent && r.result !== "pending") opponents.push(r.opponent);
    }
    let gamePoints = 0, gamesPlayed = 0, matchWins = 0;
    for (const m of members) {
      const rec = records.get(m.id);
      if (!rec) continue;
      gamePoints += rec.gamePoints;
      gamesPlayed += rec.gamesPlayed;
      matchWins += rec.matchWins;
    }
    return {
      teamId: team.id,
      name: team.name,
      rank: 0,
      points, wins, losses, draws, byes, matchWins,
      gameWinPct: gamesPlayed === 0 ? MIN_PCT : Math.max(MIN_PCT, gamePoints / (3 * gamesPlayed)),
      opponentTeamIds: opponents,
      members: members.map((m) => ({
        participantId: m.id, displayName: m.displayName, slot: m.teamSlot ?? null,
        matchWins: records.get(m.id)?.matchWins ?? 0, matchLosses: records.get(m.id)?.matchLosses ?? 0,
        matchDraws: records.get(m.id)?.matchDraws ?? 0, status: m.status,
      })),
    };
  });
  rows.sort((x, y) =>
    y.points - x.points || y.matchWins - x.matchWins || y.gameWinPct - x.gameWinPct ||
    x.name.localeCompare(y.name));
  rows.forEach((r, i) => (r.rank = i + 1));
  return rows;
}

const PLAYOFF_ORDER: Record<Playoff, number> = { winner: 0, final: 1, semifinal: 2, quarterfinal: 3 };

/**
 * Team standings: the Swiss standings between teams, and once a top 4 is cut the final order (winner, finalist,
 * the losing semifinalists by seed, then everyone else by Swiss standing). Numbers are Swiss only.
 */
export function computeTeamStandings(
  teams: Team[],
  participants: Participant[],
  rounds: RoundWithMatches[],
): TeamPlayoffStanding[] {
  const rows: TeamPlayoffStanding[] = teamSwissStandings(teams, participants, rounds)
    .map((t) => ({ ...t, swissRank: t.rank, playoff: null }));
  const played = teamPlayoffMatches(teams, participants, rounds);
  if (played.length === 0) return rows;
  const seed = teamSeeds(teams, participants, rounds);
  const reached = new Map<string, Playoff>();
  for (const m of played) {
    for (const id of m.teamIds) reached.set(id, m.stage);
    if (m.stage === "final" && m.winner) reached.set(m.winner, "winner");
  }
  for (const r of rows) r.playoff = reached.get(r.teamId) ?? null;
  rows.sort((x, y) => {
    if (x.playoff && y.playoff) {
      return PLAYOFF_ORDER[x.playoff] - PLAYOFF_ORDER[y.playoff] || (seed.get(x.teamId) ?? 99) - (seed.get(y.teamId) ?? 99);
    }
    if (x.playoff || y.playoff) return x.playoff ? -1 : 1;
    return x.swissRank - y.swissRank;
  });
  rows.forEach((r, i) => (r.rank = i + 1));
  return rows;
}

export interface TeamClinch {
  teamId: string;
  name: string;
  /** The clinching team's members' match wins (byes included), and the other team's. */
  matchWins: number;
  opponentMatchWins: number;
  /** Matches still to play: open ones in paired rounds, plus a full round of seats for each round not yet paired. */
  remaining: number;
}

/**
 * Two teams head to head (team draft, or team sealed with two teams): the team that has clinched, or null. Clinched:
 * its match wins exceed the other team's plus every match still to play, and it already tops the team standings, so
 * finishing now names it the winner. With no draws that is a majority of the event's matches. Null once nothing is
 * left to play (the event finishes the usual way) and for three or more teams.
 */
export function teamClinch(
  teams: Team[],
  participants: Participant[],
  rounds: RoundWithMatches[],
  numberOfRounds: number,
): TeamClinch | null {
  const live = teams.filter((t) => membersOf(t.id, participants, false).length > 0);
  if (live.length !== 2) return null;
  let remaining = 0;
  for (const r of rounds) for (const m of r.matches) if (!m.isBye && !isMatchScored(m)) remaining += 1;
  const paired = rounds.reduce((n, r) => Math.max(n, r.number), 0);
  const seats = Math.max(...live.map((t) => membersOf(t.id, participants).length));
  remaining += Math.max(0, numberOfRounds - paired) * seats;
  if (remaining === 0) return null;
  const [top, other] = computeTeamStandings(live, participants, rounds);
  if (top.matchWins <= other.matchWins + remaining) return null;
  return { teamId: top.teamId, name: top.name, matchWins: top.matchWins, opponentMatchWins: other.matchWins, remaining };
}

/** Team draft round: A_i meets B_((i + round) mod size). Unmatched members get byes. */
export function pairTeamDraftRound(
  teamA: Participant[],
  teamB: Participant[],
  roundNumber: number,
): ProposedMatch[] {
  const matches: ProposedMatch[] = [];
  const usedB = new Set<string>();
  const unmatched: string[] = [];
  const size = Math.max(teamA.length, teamB.length);
  teamA.forEach((a, i) => {
    let opponent: Participant | undefined;
    for (let k = 0; k < size && !opponent; k++) {
      const cand = teamB[(i + roundNumber + k) % Math.max(teamB.length, 1)];
      if (cand && !usedB.has(cand.id)) opponent = cand;
    }
    if (opponent) {
      usedB.add(opponent.id);
      matches.push({ tableNumber: matches.length + 1, side0ParticipantId: a.id, side1ParticipantId: opponent.id, isBye: false });
    } else {
      unmatched.push(a.id);
    }
  });
  for (const b of teamB) if (!usedB.has(b.id)) unmatched.push(b.id);
  for (const id of unmatched) {
    matches.push({ tableNumber: matches.length + 1, side0ParticipantId: id, side1ParticipantId: null, isBye: true });
  }
  return matches;
}

const pairKey = (a: string, b: string) => (a < b ? `${a}|${b}` : `${b}|${a}`);

function solveTeams(pool: string[], played: Set<string>): [string, string][] | null {
  if (pool.length === 0) return [];
  const [first, ...rest] = pool;
  for (let i = 0; i < rest.length; i++) {
    if (played.has(pairKey(first, rest[i]))) continue;
    const sub = solveTeams(rest.filter((_, j) => j !== i), played);
    if (sub) return [[first, rest[i]], ...sub];
  }
  return null;
}

/** Teams still playing: at least one active member (the rule the Swiss rounds and the top 4 share). */
export function activeTeams(teams: Team[], participants: Participant[]): Team[] {
  return teams.filter((t) => membersOf(t.id, participants).length > 0);
}

/**
 * The matches of team matches, the first team of a pair on side 0: each team's active members in seat order, first
 * against first and so on, so a team a player short moves its later seats up. With `bySeat` (Team Trios) seats never
 * move: a member only plays the other team's member on the same seat. A member without an opponent gets a bye, as
 * does every member of `byeTeam`. Byes take the last tables.
 */
function seatMatches(
  pairs: [string, string][], byeTeam: string | null, participants: Participant[], bySeat = false,
): ProposedMatch[] {
  const matches: ProposedMatch[] = [];
  const byes: string[] = [];
  for (const [ta, tb] of pairs) {
    let a: (Participant | undefined)[] = membersOf(ta, participants);
    let b: (Participant | undefined)[] = membersOf(tb, participants);
    if (bySeat) {
      // Line both teams up by seat number, leaving a gap where a seat has nobody active.
      const seatOf = (p: Participant | undefined) => p!.teamSlot ?? 99;
      const [ma, mb] = [a, b];
      const lined = (members: (Participant | undefined)[], seat: number, nth: number) =>
        members.filter((p) => seatOf(p) === seat)[nth];
      a = [];
      b = [];
      for (const seat of [...new Set([...ma, ...mb].map(seatOf))].sort((x, y) => x - y)) {
        const most = Math.max(ma.filter((p) => seatOf(p) === seat).length, mb.filter((p) => seatOf(p) === seat).length);
        for (let nth = 0; nth < most; nth++) {
          a.push(lined(ma, seat, nth));
          b.push(lined(mb, seat, nth));
        }
      }
    }
    const n = Math.max(a.length, b.length);
    for (let i = 0; i < n; i++) {
      const [x, y] = [a[i], b[i]];
      if (x && y) {
        matches.push({ tableNumber: matches.length + 1, side0ParticipantId: x.id, side1ParticipantId: y.id, isBye: false });
      } else {
        byes.push((x ?? y)!.id);
      }
    }
  }
  if (byeTeam) for (const m of membersOf(byeTeam, participants)) byes.push(m.id);
  for (const id of byes) {
    matches.push({ tableNumber: matches.length + 1, side0ParticipantId: id, side1ParticipantId: null, isBye: true });
  }
  return matches;
}

/**
 * Team sealed / Team Trios round: Swiss between teams, then slot vs slot inside each team match. `bySeat` (Team
 * Trios) keeps every player on their own seat when a team is a player short.
 */
export function pairTeamSwissRound(
  teams: Team[],
  participants: Participant[],
  rounds: RoundWithMatches[],
  roundNumber: number,
  rng: () => number = Math.random,
  bySeat = false,
): ProposedMatch[] {
  const live = activeTeams(teams, participants);
  if (live.length === 0) return [];
  let order: string[];
  if (roundNumber <= 1) {
    const ids = live.map((t) => t.id);
    for (let i = ids.length - 1; i > 0; i--) {
      const j = Math.floor(rng() * (i + 1));
      [ids[i], ids[j]] = [ids[j], ids[i]];
    }
    order = ids;
  } else {
    order = teamSwissStandings(live, participants, rounds).map((s) => s.teamId);
  }
  const history = teamRoundResults(live, participants, rounds);
  const played = new Set<string>();
  const hadBye = new Set<string>();
  for (const results of history.values()) {
    for (const [teamId, r] of results) {
      if (r.opponent) played.add(pairKey(teamId, r.opponent));
      if (r.result === "bye") hadBye.add(teamId);
    }
  }
  const pool = [...order];
  let byeTeam: string | null = null;
  if (pool.length % 2 === 1) {
    byeTeam = [...pool].reverse().find((t) => !hadBye.has(t)) ?? pool[pool.length - 1];
    pool.splice(pool.indexOf(byeTeam), 1);
  }
  const pairs = solveTeams(pool, played) ?? solveTeams(pool, new Set()) ?? [];
  return seatMatches(pairs, byeTeam, participants, bySeat);
}

// ── Top 4 between teams ──────────────────────────────────────────────────────────────────────────────────────

/** Why this format can't have the cut it asks for, or null: team events cut to the top 4, a team draft never. */
export function teamCutProblem(format: string | null | undefined, topCut: number): string | null {
  if (!topCut) return null;
  if (format === "team_draft") return "A team draft has no top cut";
  if (topCut !== 4) return "Team events cut to top 4";
  return null;
}

/**
 * The stage pair_round opens next for a team event, or null when every round is played. The cut counts active
 * teams (5 or more for a top 4), never players. Throws on a cut the format can't have, before round 1 and again
 * where the cut would be made, so nothing is ever mispaired.
 */
export function nextTeamStage(
  format: string | null | undefined, teams: Team[], participants: Participant[], rounds: StagedRound[],
  numberOfRounds: number, topCut: number,
): Stage | null {
  const problem = teamCutProblem(format, topCut);
  const next = nextStage(rounds, numberOfRounds, problem ? 0 : topCut, 0, activeTeams(teams, participants).length);
  if (problem && (rounds.length === 0 || next !== "swiss")) throw new Error(problem);
  return next;
}

const byTable = (x: Match, y: Match) => (x.tableNumber ?? 0) - (y.tableNumber ?? 0);

/** The team matches a round holds, in table order: the team on side 0 (the higher seed), then the other. */
function teamPairsIn(round: RoundWithMatches, teamOf: Map<string, string | null>): [string, string][] {
  const seen = new Map<string, [string, string]>();
  for (const m of round.matches.slice().sort(byTable)) {
    if (m.isBye) continue;
    const a = m.sides.find((s) => s.side === 0)?.participantId;
    const b = m.sides.find((s) => s.side === 1)?.participantId;
    const ta = a ? teamOf.get(a) : null, tb = b ? teamOf.get(b) : null;
    if (!ta || !tb || ta === tb) continue;
    if (!seen.has(pairKey(ta, tb))) seen.set(pairKey(ta, tb), [ta, tb]);
  }
  return [...seen.values()];
}

/** Seed per team: read from the semifinal tables once they are paired, else the top 4 active teams of the Swiss. */
export function teamSeeds(teams: Team[], participants: Participant[], rounds: RoundWithMatches[]): Map<string, number> {
  const out = new Map<string, number>();
  const semis = rounds.find((r) => stageOf(r as StagedRound) === "semifinal");
  if (semis) {
    const teamOf = new Map(participants.map((p) => [p.id, p.teamId ?? null]));
    const pairs = teamPairsIn(semis, teamOf).slice(0, SEMIS.length);
    if (pairs.length === SEMIS.length) {
      pairs.forEach(([hi, lo], i) => {
        out.set(hi, SEMIS[i][0]);
        out.set(lo, SEMIS[i][1]);
      });
      return out;
    }
    // A semifinal where no seat met (Team Trios: two teams each short of the seats the other still has) is all
    // byes and names no pair. The teams in the round, in Swiss order, say the rest: the pair that did meet is
    // 1 v 4 when its higher seed stands above both other teams, else 2 v 3.
    const there = new Set(semis.matches.flatMap((m) => m.sides.map((x) => (x.participantId ? teamOf.get(x.participantId) : null))));
    const order = teamSwissStandings(teams, participants, rounds).map((t) => t.teamId).filter((id) => there.has(id));
    if (pairs.length === 0) {
      order.slice(0, 4).forEach((id, i) => out.set(id, i + 1));
      return out;
    }
    const [hi, lo] = pairs[0];
    const rest = order.filter((id) => id !== hi && id !== lo).slice(0, 2);
    const slot = rest.length === 0 || order.indexOf(hi) < order.indexOf(rest[0]) ? 0 : 1;
    out.set(hi, SEMIS[slot][0]);
    out.set(lo, SEMIS[slot][1]);
    rest.forEach((id, i) => out.set(id, SEMIS[1 - slot][i]));
    return out;
  }
  const active = new Set(activeTeams(teams, participants).map((t) => t.id));
  teamSwissStandings(teams, participants, rounds)
    .filter((t) => active.has(t.teamId)).slice(0, 4)
    .forEach((t, i) => out.set(t.teamId, i + 1));
  return out;
}

/** One team against another in a playoff round. */
export interface TeamMatch {
  stage: Exclude<Stage, "swiss">;
  /** The higher seed first: its players are side 0 of every match. */
  teamIds: [string, string];
  seeds: [number | null, number | null];
  /** Individual matches won by each team, byes included. */
  wins: [number, number];
  /** pending until every match has a result. */
  status: Match["status"];
  /** The team with more wins once every match is in; level goes to the higher seed. */
  winner: string | null;
  /** The two teams' matches in this round, by table. */
  matches: Match[];
}

function teamMatch(
  stage: TeamMatch["stage"], round: RoundWithMatches, hi: string, lo: string, seed: Map<string, number>,
  teamOf: Map<string, string | null>,
): TeamMatch {
  const wins: [number, number] = [0, 0];
  const matches: Match[] = [];
  let open = false, reported = false;
  for (const m of round.matches.slice().sort(byTable)) {
    const sides = m.sides.filter((s) => s.participantId).map((s) => ({ ...s, team: teamOf.get(s.participantId!) ?? null }));
    if (!sides.length || !sides.every((s) => s.team === hi || s.team === lo)) continue;
    matches.push(m);
    if (m.isBye) {
      wins[sides[0].team === hi ? 0 : 1] += 1;
      continue;
    }
    if (!isMatchScored(m)) { open = true; continue; }
    if (m.status === "reported") reported = true;
    const a = sides.find((s) => s.side === 0), b = sides.find((s) => s.side === 1);
    if (!a || !b || a.gameWins === b.gameWins) continue;
    wins[(a.gameWins > b.gameWins ? a : b).team === hi ? 0 : 1] += 1;
  }
  return {
    stage, teamIds: [hi, lo], seeds: [seed.get(hi) ?? null, seed.get(lo) ?? null], wins,
    status: open ? "pending" : reported ? "reported" : "confirmed",
    winner: open || matches.length === 0 ? null : wins[1] > wins[0] ? lo : hi,
    matches,
  };
}

/** The team playoff matches paired so far: the semifinals (seed 1's first), then the final. */
export function teamPlayoffMatches(teams: Team[], participants: Participant[], rounds: RoundWithMatches[]): TeamMatch[] {
  const semis = rounds.find((r) => stageOf(r as StagedRound) === "semifinal");
  if (!semis) return [];
  const teamOf = new Map(participants.map((p) => [p.id, p.teamId ?? null]));
  const seed = teamSeeds(teams, participants, rounds);
  const bySeed = new Map([...seed].map(([id, n]) => [n, id]));
  const out: TeamMatch[] = [];
  for (const [x, y] of SEMIS) {
    const hi = bySeed.get(x), lo = bySeed.get(y);
    if (hi && lo) out.push(teamMatch("semifinal", semis, hi, lo, seed, teamOf));
  }
  const final = rounds.find((r) => stageOf(r as StagedRound) === "final");
  if (final) {
    // The two teams as paired; a final that is all byes (the other finalist has nobody left) names them by the
    // semifinal winners.
    let pair: string[] = teamPairsIn(final, teamOf)[0] ?? [];
    if (pair.length === 0) {
      const there = final.matches.flatMap((m) => m.sides.map((s) => (s.participantId ? teamOf.get(s.participantId) : null)));
      pair = [...new Set([...there, ...out.map((m) => m.winner)].filter((t): t is string => !!t))];
    }
    if (pair.length === 2) {
      const [hi, lo] = (seed.get(pair[0]) ?? 99) <= (seed.get(pair[1]) ?? 99) ? pair : [pair[1], pair[0]];
      out.push(teamMatch("final", final, hi, lo, seed, teamOf));
    }
  }
  return out;
}

/** Pairings for a team playoff stage. Throws when the stage before it isn't finished. `bySeat`: see seatMatches. */
export function pairTeamPlayoff(
  stage: "semifinal" | "final", teams: Team[], participants: Participant[], rounds: RoundWithMatches[], bySeat = false,
): ProposedMatch[] {
  const seed = teamSeeds(teams, participants, rounds);
  if (stage === "semifinal") {
    const bySeed = new Map([...seed].map(([id, n]) => [n, id]));
    if (bySeed.size < 4) throw new Error("Top 4 needs 5 or more teams");
    return seatMatches(SEMIS.map(([x, y]) => [bySeed.get(x)!, bySeed.get(y)!]), null, participants, bySeat);
  }
  const semis = teamPlayoffMatches(teams, participants, rounds).filter((m) => m.stage === "semifinal");
  if (semis.length !== 2 || semis.some((m) => !m.winner)) throw new Error("Every playoff match needs a winner first");
  const [a, b] = semis.map((m) => m.winner!);
  return seatMatches([(seed.get(a) ?? 99) <= (seed.get(b) ?? 99) ? [a, b] : [b, a]], null, participants, bySeat);
}

/**
 * Pairings for a team event's next round, whatever its format and stage: a team draft's rotation, Swiss between
 * teams (team sealed, Team Trios), or the top 4's team semifinals and final. Team Trios pairs by seat number.
 */
export function pairTeamStage(
  format: string | null | undefined, stage: Stage, teams: Team[], participants: Participant[], rounds: RoundWithMatches[],
  roundNumber: number, rng: () => number = Math.random,
): ProposedMatch[] {
  if (stage === "swiss") {
    if (format === "team_draft") {
      return pairTeamDraftRound(membersOf(teams[0].id, participants), membersOf(teams[1].id, participants), roundNumber);
    }
    return pairTeamSwissRound(teams, participants, rounds.filter(isSwissRound), roundNumber, rng, pairsBySeat(format));
  }
  if (stage === "quarterfinal" || !isTeamSwiss(format)) throw new Error(teamCutProblem(format, 8) ?? "Team events cut to top 4");
  return pairTeamPlayoff(stage, teams, participants, rounds, pairsBySeat(format));
}

export interface TeamBracketStage {
  stage: Exclude<Stage, "swiss">;
  matches: {
    table_number: number | null; status: Match["status"]; winner: string | null;
    sides: { seed: number | null; team_id: string; name: string | null; match_wins: number }[];
    /** The seats' matches (a bye has one side). */
    matches: {
      match_id: string; table_number: number | null; is_bye: boolean; status: Match["status"]; winner: string | null;
      sides: { participant_id: string | null; display_name: string | null; slot: number | null; game_wins: number }[];
    }[];
  }[];
}

/** The team playoff rounds paired so far, for drawing the bracket (the players' bracket, one level up). */
export function teamBracket(teams: Team[], participants: Participant[], rounds: RoundWithMatches[]): TeamBracketStage[] {
  const name = new Map(teams.map((t) => [t.id, t.name]));
  const player = new Map(participants.map((p) => [p.id, p]));
  const stages: TeamBracketStage[] = [];
  for (const tm of teamPlayoffMatches(teams, participants, rounds)) {
    let stage = stages.find((s) => s.stage === tm.stage);
    if (!stage) stages.push((stage = { stage: tm.stage, matches: [] }));
    stage.matches.push({
      table_number: tm.matches[0]?.tableNumber ?? null, status: tm.status, winner: tm.winner,
      sides: tm.teamIds.map((id, i) => ({ seed: tm.seeds[i], team_id: id, name: name.get(id) ?? null, match_wins: tm.wins[i] })),
      matches: tm.matches.map((m) => {
        const a = m.sides.find((s) => s.side === 0), b = m.sides.find((s) => s.side === 1);
        // A bye counts for its team, so its player is the winner.
        const won = m.isBye ? m.sides.find((s) => s.participantId)?.participantId ?? null
          : !isMatchScored(m) || !a || !b || a.gameWins === b.gameWins ? null
          : a.gameWins > b.gameWins ? a.participantId : b.participantId;
        return {
          match_id: m.id, table_number: m.tableNumber, is_bye: m.isBye, status: m.status, winner: won,
          sides: m.sides.slice().sort((x, y) => x.side - y.side).map((s) => ({
            participant_id: s.participantId,
            display_name: s.participantId ? player.get(s.participantId)?.displayName ?? null : null,
            slot: s.participantId ? player.get(s.participantId)?.teamSlot ?? null : null, game_wins: s.gameWins,
          })),
        };
      }),
    });
  }
  return stages;
}

/** Every active player must be on a team before a team round can be paired. */
export function teamProblems(teams: Team[], participants: Participant[], teamSize: number, format: string): string | null {
  const active = participants.filter((p) => p.status === "active");
  const loose = active.filter((p) => !p.teamId || !teams.some((t) => t.id === p.teamId));
  if (loose.length) return `${loose.length} player${loose.length === 1 ? " isn't" : "s aren't"} on a team yet`;
  if (format === "team_draft" && teams.length !== 2) return "A team draft needs exactly two teams";
  if (teams.length < 2) return "Add at least two teams";
  const over = teams.find((t) => membersOf(t.id, participants).length > teamSize);
  if (over) return `${over.name} has more than ${teamSize} players`;
  return null;
}
