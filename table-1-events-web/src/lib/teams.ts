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
//
// A member whose opponent dropped gets a bye, which counts as a match win for
// their team. A team match only counts once every one of its matches is in.
//
// Team draft: exactly two teams in one pod; each round every player meets a
// different member of the other team (A_i plays B_(i+round) mod size), which
// in alternating seats puts round 1 across the table.
// Team sealed: Swiss between teams; seat A plays seat A, B plays B, and so on.

import { buildRecords, isMatchScored } from "./standings";
import type { ProposedMatch } from "./pairings";
import type { Participant, RoundWithMatches } from "./types";

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
  members: { participantId: string; displayName: string; slot: number | null; matchWins: number; status: Participant["status"] }[];
}

const MIN_PCT = 1 / 3;

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

export function computeTeamStandings(
  teams: Team[],
  participants: Participant[],
  rounds: RoundWithMatches[],
): TeamStanding[] {
  const records = buildRecords(participants, rounds);
  const perRound = teamRoundResults(teams, participants, rounds);
  const rows: TeamStanding[] = teams.map((team) => {
    const members = membersOf(team.id, participants, false);
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
        matchWins: records.get(m.id)?.matchWins ?? 0, status: m.status,
      })),
    };
  });
  rows.sort((x, y) =>
    y.points - x.points || y.matchWins - x.matchWins || y.gameWinPct - x.gameWinPct ||
    x.name.localeCompare(y.name));
  rows.forEach((r, i) => (r.rank = i + 1));
  return rows;
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

/** Team sealed round: Swiss between teams, then slot vs slot inside each team match. */
export function pairTeamSwissRound(
  teams: Team[],
  participants: Participant[],
  rounds: RoundWithMatches[],
  roundNumber: number,
  rng: () => number = Math.random,
): ProposedMatch[] {
  const live = teams.filter((t) => membersOf(t.id, participants).length > 0);
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
    order = computeTeamStandings(live, participants, rounds).map((s) => s.teamId);
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

  const matches: ProposedMatch[] = [];
  const byes: string[] = [];
  for (const [ta, tb] of pairs) {
    const a = membersOf(ta, participants);
    const b = membersOf(tb, participants);
    const n = Math.max(a.length, b.length);
    for (let i = 0; i < n; i++) {
      if (a[i] && b[i]) {
        matches.push({ tableNumber: matches.length + 1, side0ParticipantId: a[i].id, side1ParticipantId: b[i].id, isBye: false });
      } else {
        byes.push((a[i] ?? b[i]).id);
      }
    }
  }
  if (byeTeam) for (const m of membersOf(byeTeam, participants)) byes.push(m.id);
  for (const id of byes) {
    matches.push({ tableNumber: matches.length + 1, side0ParticipantId: id, side1ParticipantId: null, isBye: true });
  }
  return matches;
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
