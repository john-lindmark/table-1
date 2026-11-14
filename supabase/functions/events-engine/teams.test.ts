// Team events: Team Trios beside team sealed, and the top 4 between teams (team semifinals 1v4 and 2v3, a team
// final, final places for every member). Whole simulated events, checked round by round.
// Runs under Deno (`deno test`) and Node 23+ (`node --test teams.test.ts`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { mulberry32, type ProposedMatch } from "./pairings.ts";
import { bracket, nextStep, playoffStandings, swissRounds, type Stage, type StagedRound } from "./playoffs.ts";
import { placementRows } from "./placements.ts";
import {
  activeTeams, computeTeamStandings, isTeamEvent, isTeamSwiss, membersOf, nextTeamStage, pairsBySeat, pairTeamPlayoff,
  pairTeamStage, pairTeamSwissRound, teamBracket, teamCutProblem, teamPlayoffMatches, teamProblems, teamRoundResults,
  teamSeeds, teamSwissStandings, type Team,
} from "./teams.ts";
import type { Participant } from "./types.ts";

const LETTERS = "abcd";
const makeTeams = (n: number): Team[] =>
  Array.from({ length: n }, (_, i) => ({ id: `t${String(i + 1).padStart(2, "0")}`, name: `Team ${String.fromCharCode(65 + i)}`, order: i }));
const makePlayers = (teams: Team[], size: number): Participant[] =>
  teams.flatMap((t) => Array.from({ length: size }, (_, s) => ({
    id: `${t.id}${LETTERS[s]}`, eventId: "e", podId: "pod", displayName: `${t.name} ${LETTERS[s].toUpperCase()}`, seat: null,
    status: "active" as const, droppedInRound: null, teamId: t.id, teamSlot: s + 1,
  })));
const teamOfId = (id: string) => id.slice(0, 3);
const drop = (ps: Participant[], gone: (p: Participant) => boolean, round: number): Participant[] =>
  ps.map((p) => (gone(p) ? { ...p, status: "dropped" as const, droppedInRound: round } : p));

let ids = 0;
/** A played round: `winner` picks each match's winner (2–0, or 2–1 when the pick says so). */
function play(stage: Stage, number: number, proposed: ProposedMatch[], winner: (a: string, b: string, table: number) => string,
              status: "confirmed" | "reported" | "pending" = "confirmed"): StagedRound {
  const roundId = `r${number}`;
  return {
    id: roundId, eventId: "e", number, status: "recorded", stage, timerDurationSeconds: 3000,
    timerRemainingAtChange: 3000, timerStatus: "running", timerLastStartedAt: null,
    matches: proposed.map((m) => {
      const id = `m${++ids}`;
      const w = m.isBye ? m.side0ParticipantId : winner(m.side0ParticipantId, m.side1ParticipantId!, m.tableNumber);
      return {
        id, eventId: "e", roundId, tableNumber: m.tableNumber, isBye: m.isBye, gameDraws: 0, intentionalDraw: false,
        status: m.isBye ? "confirmed" as const : status,
        sides: [
          { id: `${id}a`, matchId: id, participantId: m.side0ParticipantId, side: 0 as const, gameWins: m.isBye || w === m.side0ParticipantId ? 2 : number % 2 },
          ...(m.side1ParticipantId ? [{ id: `${id}b`, matchId: id, participantId: m.side1ParticipantId, side: 1 as const,
            gameWins: w === m.side1ParticipantId ? 2 : number % 2 }] : []),
        ],
      };
    }),
  };
}

/** The Swiss rounds of a team event with random results; `afterRound` may drop players along the way. */
function teamSwiss(format: string, count: number, size: number, seed: number,
                   afterRound: (round: number, ps: Participant[]) => Participant[] = (_r, ps) => ps) {
  const rng = mulberry32(seed);
  const teams = makeTeams(count);
  let ps = makePlayers(teams, size);
  const rounds: StagedRound[] = [];
  const total = swissRounds(count);
  const pairings: ProposedMatch[][] = [];
  for (let r = 1; r <= total; r++) {
    assert.equal(nextTeamStage(format, teams, ps, rounds, total, 4), "swiss");
    const proposed = pairTeamStage(format, "swiss", teams, ps, rounds, r, rng);
    pairings.push(proposed);
    rounds.push(play("swiss", r, proposed, (a, b) => (rng() < 0.5 ? a : b)));
    ps = afterRound(r, ps);
  }
  return { teams, ps, rounds, total, rng, pairings };
}

/** Who a team match goes to, worked out here from the played round: more seats won (byes count); level → `hi`. */
function teamWinner(round: StagedRound, hi: string, lo: string): string {
  let a = 0, b = 0;
  for (const m of round.matches) {
    const sides = m.sides.filter((s) => s.participantId);
    if (!sides.every((s) => [hi, lo].includes(teamOfId(s.participantId!)))) continue;
    const won = m.isBye ? sides[0] : sides[0].gameWins > sides[1].gameWins ? sides[0] : sides[1];
    if (teamOfId(won.participantId!) === hi) a++; else b++;
  }
  return b > a ? lo : hi;
}

test("Team Trios is a team event paired as Swiss between teams, like team sealed; never a draft", () => {
  assert.deepEqual(["team_draft", "team_sealed", "team_trios", "sealed", "draft", "modern", null].map(isTeamEvent),
                   [true, true, true, false, false, false, false]);
  assert.deepEqual(["team_draft", "team_sealed", "team_trios", "sealed", undefined].map(isTeamSwiss), [false, true, true, false, false]);
  const teams = makeTeams(6);
  const ps = makePlayers(teams, 3);
  assert.equal(teamProblems(teams, ps, 3, "team_trios"), null);
  assert.match(teamProblems(teams, [...ps, { ...ps[0], id: "loose", teamId: null, teamSlot: null }], 3, "team_trios")!, /isn't on a team/);
  // More than two teams is fine (only a team draft is held to two).
  assert.match(teamProblems(teams, ps, 3, "team_draft")!, /exactly two/);
});

test("team_trios pairs and ranks exactly as team_sealed does for the same results, cut included (full teams)", () => {
  for (const count of [2, 3, 5, 6, 8, 11]) {
    const sealed = teamSwiss("team_sealed", count, 3, 40 + count);
    const trios = teamSwiss("team_trios", count, 3, 40 + count);
    const why = `${count} teams`;
    assert.deepEqual(trios.pairings, sealed.pairings, why);
    // Each seat plays the same seat: slot 1 against slot 1, and so on (teams at full strength).
    for (const m of sealed.pairings[0].filter((x) => !x.isBye)) assert.equal(m.side0ParticipantId.at(-1), m.side1ParticipantId!.at(-1), why);
    const strip = (rounds: StagedRound[]) => JSON.parse(JSON.stringify(rounds).replace(/"m\d+[ab]?"/g, '"m"'));
    assert.deepEqual(strip(trios.rounds), strip(sealed.rounds), why);
    assert.deepEqual(computeTeamStandings(trios.teams, trios.ps, trios.rounds), computeTeamStandings(sealed.teams, sealed.ps, sealed.rounds), why);
    assert.deepEqual(nextTeamStage("team_trios", trios.teams, trios.ps, trios.rounds, trios.total, 4),
                     nextTeamStage("team_sealed", sealed.teams, sealed.ps, sealed.rounds, sealed.total, 4), why);
    if (activeTeams(sealed.teams, sealed.ps).length > 4) {
      assert.deepEqual(pairTeamStage("team_trios", "semifinal", trios.teams, trios.ps, trios.rounds, trios.total + 1),
                       pairTeamStage("team_sealed", "semifinal", sealed.teams, sealed.ps, sealed.rounds, sealed.total + 1), why);
    }
  }
});

test("team top 4, 5 to 12 teams of 3 and of 4: seeds, team semifinals and final, final places for every member", () => {
  for (const size of [3, 4]) {
    for (let count = 5; count <= 12; count++) {
      for (const seed of [1, 2, 3, 4]) {
        const format = seed % 2 ? "team_trios" : "team_sealed";
        const { teams, ps, rounds, total, rng } = teamSwiss(size === 3 ? format : "team_sealed", count, size, count * 100 + size * 10 + seed);
        const why = `${count} teams of ${size}, seed ${seed}`;
        const swiss = teamSwissStandings(teams, ps, rounds);
        assert.deepEqual(computeTeamStandings(teams, ps, rounds).map((t) => [t.teamId, t.rank, t.swissRank, t.playoff]),
                         swiss.map((t) => [t.teamId, t.rank, t.rank, null]), why);
        const top = swiss.slice(0, 4).map((t) => t.teamId);
        assert.deepEqual([...teamSeeds(teams, ps, rounds)].sort((a, b) => a[1] - b[1]).map(([id]) => id), top, why);
        assert.deepEqual(teamPlayoffMatches(teams, ps, rounds), [], why);
        assert.deepEqual(teamBracket(teams, ps, rounds), [], why);

        // The cut counts teams: the step is cut4, the stage the semifinals.
        assert.equal(nextStep({ stages: rounds.map((r) => r.stage!), waiting: false, numberOfRounds: total, topCut: 4,
                                activePlayers: ps.length, activeTeams: count }), "cut4", why);
        assert.equal(nextTeamStage("team_sealed", teams, ps, rounds, total, 4), "semifinal", why);
        assert.equal(nextTeamStage("team_sealed", teams, ps, rounds, total, 0), null, why);

        // Semifinals: seed 1 v 4 on the first tables, 2 v 3 after; slot against slot; the higher seed is side 0.
        const sf = pairTeamStage("team_sealed", "semifinal", teams, ps, rounds, total + 1);
        assert.deepEqual(sf, pairTeamPlayoff("semifinal", teams, ps, rounds), why);
        const want = [[top[0], top[3]], [top[1], top[2]]].flatMap(([hi, lo]) =>
          Array.from({ length: size }, (_, s) => [`${hi}${LETTERS[s]}`, `${lo}${LETTERS[s]}`]));
        assert.deepEqual(sf.map((m) => [m.side0ParticipantId, m.side1ParticipantId, m.isBye]), want.map(([a, b]) => [a, b, false]), why);
        assert.deepEqual(sf.map((m) => m.tableNumber), Array.from({ length: 2 * size }, (_, i) => i + 1), why);
        // Every member of a seeded team plays exactly once, nobody else does.
        assert.deepEqual(sf.flatMap((m) => [m.side0ParticipantId, m.side1ParticipantId!]).sort(),
                         ps.filter((p) => top.includes(p.teamId!)).map((p) => p.id).sort(), why);

        // Teams of 4: the first semifinal is split 2–2 and goes to the higher seed. Otherwise random.
        const split = size === 4 && seed % 2 === 1;
        const semis = play("semifinal", total + 1, sf, (a, b, table) => (split && table <= 4 ? (table <= 2 ? b : a) : rng() < 0.5 ? a : b));
        rounds.push(semis);
        const w1 = teamWinner(semis, top[0], top[3]), w2 = teamWinner(semis, top[1], top[2]);
        if (split) assert.equal(w1, top[0], why);
        let played = teamPlayoffMatches(teams, ps, rounds);
        assert.deepEqual(played.map((m) => [m.stage, m.teamIds, m.seeds, m.winner, m.status, m.matches.length]), [
          ["semifinal", [top[0], top[3]], [1, 4], w1, "confirmed", size], ["semifinal", [top[1], top[2]], [2, 3], w2, "confirmed", size],
        ], why);
        assert.ok(played.every((m) => m.wins[0] + m.wins[1] === size), why);
        if (split) assert.deepEqual(played[0].wins, [2, 2], why);
        // Seeds now come from the tables: a whole seeded team dropping afterwards moves nothing.
        const loser1 = w1 === top[0] ? top[3] : top[0], loser2 = w2 === top[1] ? top[2] : top[1];
        const later = drop(ps, (p) => p.teamId === loser1, total + 1);
        assert.deepEqual([...teamSeeds(teams, later, rounds)].sort((a, b) => a[1] - b[1]).map(([id]) => id), top, why);

        // The final: the two winners, the higher seed on side 0.
        assert.equal(nextTeamStage("team_sealed", teams, later, rounds, total, 4), "final", why);
        const finalists = [w1, w2].sort((a, b) => top.indexOf(a) - top.indexOf(b));
        const fin = pairTeamStage("team_sealed", "final", teams, later, rounds, total + 2);
        assert.deepEqual(fin.map((m) => [m.tableNumber, m.side0ParticipantId, m.side1ParticipantId, m.isBye]),
                         Array.from({ length: size }, (_, s) => [s + 1, `${finalists[0]}${LETTERS[s]}`, `${finalists[1]}${LETTERS[s]}`, false]), why);
        const final = play("final", total + 2, fin, (a, b) => (rng() < 0.5 ? a : b));
        rounds.push(final);
        const champion = teamWinner(final, finalists[0], finalists[1]);
        assert.equal(nextTeamStage("team_sealed", teams, later, rounds, total, 4), null, why);

        // Final order: winner, finalist, the losing semifinalists by seed, then everyone else by Swiss standing.
        const standings = computeTeamStandings(teams, later, rounds);
        const semifinalLosers = [loser1, loser2].sort((a, b) => top.indexOf(a) - top.indexOf(b));
        assert.deepEqual(standings.slice(0, 4).map((t) => [t.teamId, t.playoff]), [
          [champion, "winner"], [finalists.find((t) => t !== champion), "final"],
          [semifinalLosers[0], "semifinal"], [semifinalLosers[1], "semifinal"],
        ], why);
        assert.deepEqual(standings.map((t) => t.rank), standings.map((_, i) => i + 1), why);
        assert.equal(new Set(standings.map((t) => t.teamId)).size, count, why);
        assert.deepEqual(standings.slice(4).map((t) => t.teamId), swiss.slice(4).map((t) => t.teamId), why);
        assert.ok(standings.slice(4).every((t) => t.playoff === null), why);
        // Points, records and tiebreakers are the Swiss ones: playoff rounds only decide the order.
        for (const t of standings) {
          const s = swiss.find((x) => x.teamId === t.teamId)!;
          assert.deepEqual([t.swissRank, t.points, t.wins, t.losses, t.draws, t.byes, t.matchWins, t.gameWinPct],
                           [s.rank, s.points, s.wins, s.losses, s.draws, s.byes, s.matchWins, s.gameWinPct], why);
          assert.deepEqual(t.members.map((m) => [m.participantId, m.matchWins, m.matchLosses]),
                           s.members.map((m) => [m.participantId, m.matchWins, m.matchLosses]), why);
        }

        // Every member carries the team's final place and playoff stage; players keep their own Swiss record.
        const rows = placementRows(later, rounds, teams, true);
        assert.equal(rows.length, ps.length, why);
        for (const row of rows) {
          const t = standings.find((x) => x.teamId === teamOfId(row.participant_id))!;
          assert.deepEqual([row.place, row.playoff, row.team_id], [t.rank, t.playoff, t.teamId], `${why} ${row.participant_id}`);
        }
        assert.deepEqual(rows.filter((r) => r.place === 1).map((r) => r.participant_id).sort(),
                         ps.filter((p) => p.teamId === champion).map((p) => p.id).sort(), why);
        assert.ok(rows.filter((r) => r.place === 1).every((r) => r.playoff === "winner"), why);
        const places = [...new Set(rows.map((r) => r.place))].sort((a, b) => a - b);
        assert.deepEqual(places, Array.from({ length: count }, (_, i) => i + 1), why);
        const own = new Map(playoffStandings(later, rounds.filter((r) => r.stage === "swiss")).map((s) => [s.participantId, s]));
        for (const row of rows) assert.equal(row.match_points, own.get(row.participant_id)!.matchPoints, why);

        // The players' own standings stay Swiss, and there is no bracket of players: the bracket is the teams'.
        assert.deepEqual(playoffStandings(later, rounds).map((s) => [s.participantId, s.rank, s.playoff]),
                         [...own.values()].map((s) => [s.participantId, s.rank, null]), why);
        assert.deepEqual(bracket(later, rounds), [], why);
        const b = teamBracket(teams, later, rounds);
        assert.deepEqual(b.map((s) => [s.stage, s.matches.length]), [["semifinal", 2], ["final", 1]], why);
        assert.deepEqual(b[0].matches.map((m) => m.sides.map((s) => [s.seed, s.team_id])), [[[1, top[0]], [4, top[3]]], [[2, top[1]], [3, top[2]]]], why);
        assert.deepEqual(b[0].matches.map((m) => [m.winner, m.table_number, m.matches.length]), [[w1, 1, size], [w2, size + 1, size]], why);
        assert.deepEqual(b[1].matches.map((m) => [m.winner, m.sides.map((s) => s.team_id), m.status]), [[champion, finalists, "confirmed"]], why);
        assert.equal(b[1].matches[0].sides[0].match_wins + b[1].matches[0].sides[1].match_wins, size, why);
        assert.equal(b[1].matches[0].sides[0].name, teams.find((t) => t.id === finalists[0])!.name, why);
        assert.deepEqual(b[1].matches[0].matches[0].sides.map((s) => [s.participant_id, s.slot]),
                         [[`${finalists[0]}a`, 1], [`${finalists[1]}a`, 1]], why);
        played = teamPlayoffMatches(teams, later, rounds);
        assert.deepEqual(played.map((m) => m.stage), ["semifinal", "semifinal", "final"], why);
      }
    }
  }
});

test("a 2–2 split with teams of 4 goes to the higher seed, in the semifinals and in the final", () => {
  const { teams, ps, rounds, total } = teamSwiss("team_sealed", 6, 4, 77);
  const top = teamSwissStandings(teams, ps, rounds).slice(0, 4).map((t) => t.teamId);
  // Both semifinals 2–2: seats A and B to the lower seed, C and D to the higher.
  const split = (a: string, b: string) => ("ab".includes(a.at(-1)!) ? b : a);
  rounds.push(play("semifinal", total + 1, pairTeamPlayoff("semifinal", teams, ps, rounds), split));
  const semis = teamPlayoffMatches(teams, ps, rounds);
  assert.deepEqual(semis.map((m) => [m.wins, m.winner]), [[[2, 2], top[0]], [[2, 2], top[1]]]);
  const fin = pairTeamPlayoff("final", teams, ps, rounds);
  assert.deepEqual([teamOfId(fin[0].side0ParticipantId), teamOfId(fin[0].side1ParticipantId!)], [top[0], top[1]]);
  rounds.push(play("final", total + 2, fin, split));
  const standings = computeTeamStandings(teams, ps, rounds);
  assert.deepEqual(standings.slice(0, 4).map((t) => [t.teamId, t.playoff]),
                   [[top[0], "winner"], [top[1], "final"], [top[2], "semifinal"], [top[3], "semifinal"]]);
  // 3–1 to the lower seed is a win for the lower seed.
  const upset = [...rounds.slice(0, -1), play("final", total + 2, fin, (a, b) => (a.endsWith("a") ? a : b))];
  assert.equal(computeTeamStandings(teams, ps, upset)[0].teamId, top[1]);
});

test("a team match waits for every seat: no winner, no final, until all results are in", () => {
  const { teams, ps, rounds, total } = teamSwiss("team_trios", 5, 3, 5);
  const sf = pairTeamPlayoff("semifinal", teams, ps, rounds);
  const open = play("semifinal", total + 1, sf, (a) => a);
  open.matches[4].status = "pending";
  const top = teamSwissStandings(teams, ps, rounds).slice(0, 4).map((t) => t.teamId);
  assert.deepEqual(teamPlayoffMatches(teams, ps, [...rounds, open]).map((m) => [m.status, m.winner]), [["confirmed", top[0]], ["pending", null]]);
  assert.throws(() => pairTeamPlayoff("final", teams, ps, [...rounds, open]), /needs a winner/);
  assert.throws(() => pairTeamPlayoff("final", teams, ps, rounds), /needs a winner/);
  // Both semifinalists of the open match still read as semifinalists, by seed.
  assert.deepEqual(computeTeamStandings(teams, ps, [...rounds, open]).slice(0, 4).map((t) => [t.teamId, t.playoff]),
                   top.map((id) => [id, "semifinal"]));
  // A result that is in but not yet confirmed counts, as it does everywhere else.
  const reported = play("semifinal", total + 1, sf, (a) => a, "reported");
  assert.deepEqual(teamPlayoffMatches(teams, ps, [...rounds, reported]).map((m) => [m.status, m.winner]), [["reported", top[0]], ["reported", top[1]]]);
});

test("team sealed drops: a team is in while it has an active member; a missing seat gives the other team a bye win", () => {
  // Seat B of team t01 drops after round 1 (team size 3); everything else plays on.
  const { teams, ps, rounds, total } = teamSwiss("team_sealed", 6, 3, 21, (r, all) => (r === 1 ? drop(all, (p) => p.id === "t01b", 1) : all));
  // As in the Swiss rounds: the team keeps playing a seat short, its active members move up a seat, and the
  // opposing team's last seat has a bye.
  const round2 = rounds[1];
  const t01 = round2.matches.filter((m) => m.sides.some((s) => teamOfId(s.participantId!) === "t01"));
  if (t01.some((m) => !m.isBye)) {
    const opp = teamOfId(t01.find((m) => !m.isBye)!.sides.find((s) => teamOfId(s.participantId!) !== "t01")!.participantId!);
    assert.deepEqual(round2.matches.filter((m) => m.isBye && teamOfId(m.sides[0].participantId!) === opp).map((m) => m.sides[0].participantId), [`${opp}c`]);
  }
  assert.equal(activeTeams(teams, ps).length, 6);
  // Make t01 a seed whatever the random results were: check it against the standings it earned.
  const swiss = teamSwissStandings(teams, ps, rounds);
  const top = swiss.slice(0, 4).map((t) => t.teamId);
  assert.deepEqual([...teamSeeds(teams, ps, rounds).keys()], top);
  const sf = pairTeamPlayoff("semifinal", teams, ps, rounds);
  for (const [hi, lo] of [[top[0], top[3]], [top[1], top[2]]]) {
    const a = membersOf(hi, ps), b = membersOf(lo, ps);
    const real = sf.filter((m) => !m.isBye && teamOfId(m.side0ParticipantId) === hi);
    assert.deepEqual(real.map((m) => [m.side0ParticipantId, m.side1ParticipantId]),
                     Array.from({ length: Math.min(a.length, b.length) }, (_, i) => [a[i].id, b[i].id]));
  }
  if (top.includes("t01")) {
    const other = sf.find((m) => !m.isBye && [m.side0ParticipantId, m.side1ParticipantId].some((id) => teamOfId(id!) === "t01"))!;
    const opp = [other.side0ParticipantId, other.side1ParticipantId!].map(teamOfId).find((t) => t !== "t01")!;
    assert.deepEqual(sf.filter((m) => m.isBye).map((m) => m.side0ParticipantId), [`${opp}c`]);
    assert.equal(sf.at(-1)!.isBye, true);
  }
});

/** Six teams of 3, scripted so t01 finishes first: the lower team id wins every Swiss match. */
function scripted(format: string) {
  const teams = makeTeams(6);
  const ps = makePlayers(teams, 3);
  const rounds: StagedRound[] = [];
  const total = swissRounds(6);
  for (let r = 1; r <= total; r++) {
    rounds.push(play("swiss", r, pairTeamStage(format, "swiss", teams, ps, rounds, r, mulberry32(r)), (a, b) => (a < b ? a : b)));
  }
  const top = teamSwissStandings(teams, ps, rounds).slice(0, 4).map((t) => t.teamId);
  assert.equal(top[0], "t01");
  return { teams, ps, rounds, total, top };
}

test("team sealed, a short-handed seed: the bye counts for the other team, so one real win is enough for it", () => {
  const { teams, rounds, total, top, ...rest } = scripted("team_sealed");
  const ps = drop(rest.ps, (p) => p.id === "t01b", total);
  assert.equal(nextTeamStage("team_sealed", teams, ps, rounds, total, 4), "semifinal");
  assert.deepEqual([...teamSeeds(teams, ps, rounds).keys()], top);
  const sf = pairTeamPlayoff("semifinal", teams, ps, rounds);
  assert.deepEqual(pairTeamStage("team_sealed", "semifinal", teams, ps, rounds, total + 1), sf);
  const four = top[3];
  assert.deepEqual(sf.filter((m) => teamOfId(m.side0ParticipantId) === "t01").map((m) => [m.side0ParticipantId, m.side1ParticipantId]),
                   [["t01a", `${four}a`], ["t01c", `${four}b`]]);
  assert.deepEqual(sf.filter((m) => m.isBye).map((m) => [m.tableNumber, m.side0ParticipantId]), [[6, `${four}c`]]);
  // 1–1 at the tables plus the bye: seed 4 wins 2–1.
  const split = play("semifinal", total + 1, sf, (a, b) => (a === "t01a" ? a : a === "t01c" ? b : a));
  const m = teamPlayoffMatches(teams, ps, [...rounds, split])[0];
  assert.deepEqual([m.teamIds, m.wins, m.winner, m.matches.length], [["t01", four], [1, 2], four, 3]);
  // Seed 1 needs both of its matches: 2–1 with the bye against it.
  const both = play("semifinal", total + 1, sf, (a) => a);
  assert.deepEqual(teamPlayoffMatches(teams, ps, [...rounds, both])[0].wins, [2, 1]);
  assert.equal(teamPlayoffMatches(teams, ps, [...rounds, both])[0].winner, "t01");
  const tb = teamBracket(teams, ps, [...rounds, split])[0].matches[0];
  assert.deepEqual(tb.sides.map((s) => [s.seed, s.team_id, s.match_wins]), [[1, "t01", 1], [4, four, 2]]);
  assert.deepEqual(tb.matches.at(-1)!.sides.map((s) => s.participant_id), [`${four}c`]);
  assert.equal(tb.matches.at(-1)!.is_bye, true);
  assert.equal(tb.matches.at(-1)!.winner, `${four}c`);
});

test("a team with nobody left isn't seeded: its place goes to the next team, and four teams left means no cut", () => {
  const { teams, ps, rounds, total } = teamSwiss("team_sealed", 6, 3, 9);
  const order = teamSwissStandings(teams, ps, rounds).map((t) => t.teamId);
  const gone = drop(ps, (p) => p.teamId === order[1], total);
  assert.equal(activeTeams(teams, gone).length, 5);
  assert.deepEqual([...teamSeeds(teams, gone, rounds)].sort((a, b) => a[1] - b[1]).map(([id]) => id), [order[0], order[2], order[3], order[4]]);
  assert.equal(nextTeamStage("team_sealed", teams, gone, rounds, total, 4), "semifinal");
  const sf = pairTeamPlayoff("semifinal", teams, gone, rounds);
  assert.ok(sf.every((m) => ![m.side0ParticipantId, m.side1ParticipantId].some((id) => id && teamOfId(id) === order[1])));
  const four = drop(gone, (p) => p.teamId === order[5], total);
  assert.equal(activeTeams(teams, four).length, 4);
  assert.equal(nextTeamStage("team_sealed", teams, four, rounds, total, 4), null);
  // Five teams exactly make a cut; four never do.
  const five = teamSwiss("team_trios", 5, 3, 3);
  assert.equal(nextTeamStage("team_trios", five.teams, five.ps, five.rounds, five.total, 4), "semifinal");
  const small = teamSwiss("team_trios", 4, 3, 3);
  assert.equal(nextTeamStage("team_trios", small.teams, small.ps, small.rounds, small.total, 4), null);
  assert.throws(() => pairTeamPlayoff("semifinal", small.teams.slice(0, 3), small.ps.filter((p) => p.teamId !== "t04"), small.rounds), /5 or more teams/);
});

test("a finalist with nobody left: the other team's seats all have byes and it wins", () => {
  const { teams, ps, rounds, total } = teamSwiss("team_trios", 5, 3, 12);
  const top = teamSwissStandings(teams, ps, rounds).slice(0, 4).map((t) => t.teamId);
  rounds.push(play("semifinal", total + 1, pairTeamPlayoff("semifinal", teams, ps, rounds), (a) => a));
  const gone = drop(ps, (p) => p.teamId === top[0], total + 1);
  const fin = pairTeamPlayoff("final", teams, gone, rounds);
  assert.deepEqual(fin.map((m) => [m.side0ParticipantId, m.isBye]), ["a", "b", "c"].map((s) => [`${top[1]}${s}`, true]));
  rounds.push(play("final", total + 2, fin, (a) => a));
  const final = teamPlayoffMatches(teams, gone, rounds).at(-1)!;
  assert.deepEqual([final.stage, final.teamIds, final.wins, final.winner], ["final", [top[0], top[1]], [0, 3], top[1]]);
  assert.deepEqual(computeTeamStandings(teams, gone, rounds).slice(0, 4).map((t) => [t.teamId, t.playoff]),
                   [[top[1], "winner"], [top[0], "final"], [top[2], "semifinal"], [top[3], "semifinal"]]);
});

test("cuts a team event can't have are refused: a top 8 between teams, any cut in a team draft", () => {
  assert.equal(teamCutProblem("team_sealed", 0), null);
  assert.equal(teamCutProblem("team_trios", 4), null);
  assert.equal(teamCutProblem("team_draft", 0), null);
  assert.match(teamCutProblem("team_sealed", 8)!, /top 4/);
  assert.match(teamCutProblem("team_trios", 8)!, /top 4/);
  assert.match(teamCutProblem("team_draft", 4)!, /team draft has no top cut/);
  assert.match(teamCutProblem("team_draft", 8)!, /team draft has no top cut/);

  for (const format of ["team_sealed", "team_trios"]) {
    const { teams, ps, rounds, total } = teamSwiss(format, 9, 3, 30);
    // Before round 1 and again where the cut would be made; the Swiss rounds in between still pair.
    assert.throws(() => nextTeamStage(format, teams, ps, [], total, 8), /Team events cut to top 4/);
    assert.equal(nextTeamStage(format, teams, ps, rounds.slice(0, 2), total, 8), "swiss");
    assert.throws(() => nextTeamStage(format, teams, ps, rounds, total, 8), /Team events cut to top 4/);
    assert.throws(() => pairTeamStage(format, "quarterfinal", teams, ps, rounds, total + 1), /Team events cut to top 4/);
    // The step the clients show never offers that cut either.
    assert.equal(nextStep({ stages: rounds.map((r) => r.stage!), waiting: false, numberOfRounds: total, topCut: 8,
                            activePlayers: 27, activeTeams: 9 }), "finish");
  }
  // A team draft: two teams, three rounds, no cut of any size.
  const teams = makeTeams(2);
  const ps = makePlayers(teams, 3);
  for (const cut of [4, 8]) {
    assert.throws(() => nextTeamStage("team_draft", teams, ps, [], 3, cut), /team draft has no top cut/);
  }
  assert.equal(nextTeamStage("team_draft", teams, ps, [], 3, 0), "swiss");
  const rounds: StagedRound[] = [];
  for (let r = 1; r <= 3; r++) rounds.push(play("swiss", r, pairTeamStage("team_draft", "swiss", teams, ps, rounds, r), (a) => a));
  assert.equal(nextTeamStage("team_draft", teams, ps, rounds, 3, 0), null);
  assert.throws(() => nextTeamStage("team_draft", teams, ps, rounds, 3, 4), /team draft has no top cut/);
  assert.throws(() => pairTeamStage("team_draft", "semifinal", teams, ps, rounds, 4), /team draft has no top cut/);
  assert.throws(() => pairTeamStage("team_draft", "final", teams, ps, rounds, 4), /team draft has no top cut/);
});

test("a team draft still pairs its rotation through pairTeamStage, and team events without a cut stop at their rounds", () => {
  const teams = makeTeams(2);
  const ps = makePlayers(teams, 3);
  const r1 = pairTeamStage("team_draft", "swiss", teams, ps, [], 1);
  assert.deepEqual(r1.map((m) => [m.side0ParticipantId, m.side1ParticipantId]), [["t01a", "t02b"], ["t01b", "t02c"], ["t01c", "t02a"]]);
  const sealed = teamSwiss("team_sealed", 8, 3, 2);
  assert.equal(nextTeamStage("team_sealed", sealed.teams, sealed.ps, sealed.rounds, sealed.total, 0), null);
  assert.equal(nextTeamStage("team_sealed", sealed.teams, sealed.ps, sealed.rounds.slice(0, 1), sealed.total, 0), "swiss");
});

// ---------------------------------------------------------------------------------------------------------------
// Team Trios pairs by seat number, always: each seat is a format, so a dropped seat never moves the others up.

/** Who meets whom, whichever team is on side 0: "t01a-t02a" for a match, the lone player for a bye. */
const seatsOf = (ms: ProposedMatch[]) => ({
  matches: ms.filter((m) => !m.isBye).map((m) => [m.side0ParticipantId, m.side1ParticipantId!].sort().join("-")).sort(),
  byes: ms.filter((m) => m.isBye).map((m) => m.side0ParticipantId).sort(),
});

test("Team Trios pairs by seat number: only team_trios, never team sealed or a team draft", () => {
  assert.deepEqual(["team_trios", "team_sealed", "team_draft", "sealed", null].map(pairsBySeat), [true, false, false, false, false]);
});

test("Team Trios, Swiss: seat B dropped, seat C still plays seat C and the other team's seat B has the bye", () => {
  const teams = makeTeams(2);
  const ps = drop(makePlayers(teams, 3), (p) => p.id === "t01b", 1);
  for (const seed of [1, 2, 3, 4, 5]) {
    const trios = pairTeamStage("team_trios", "swiss", teams, ps, [], 2, mulberry32(seed));
    assert.deepEqual(seatsOf(trios), { matches: ["t01a-t02a", "t01c-t02c"], byes: ["t02b"] });
    // The matches keep the first tables, the bye the last.
    assert.deepEqual(trios.map((m) => [m.tableNumber, m.isBye]), [[1, false], [2, false], [3, true]]);
    // Team sealed with the same drop is as it always was: seats move up and the last seat has the bye.
    const sealed = pairTeamStage("team_sealed", "swiss", teams, ps, [], 2, mulberry32(seed));
    assert.deepEqual(seatsOf(sealed), { matches: ["t01a-t02a", "t01c-t02b"], byes: ["t02c"] });
    assert.deepEqual(pairTeamSwissRound(teams, ps, [], 2, mulberry32(seed)), sealed);
    assert.deepEqual(pairTeamSwissRound(teams, ps, [], 2, mulberry32(seed), true), trios);
  }
  // The bye is a match win for its team, as byes already are: t02 takes the round 2–1 with one real win.
  const proposed = pairTeamStage("team_trios", "swiss", teams, ps, [], 1, mulberry32(1));
  const split = play("swiss", 1, proposed, (a, b) => ([a, b].includes("t01a") ? "t01a" : [a, b].find((id) => id.startsWith("t02"))!));
  assert.deepEqual(teamRoundResults(teams, ps, [split]).get(1)!.get("t02"), { result: "win", opponent: "t01", won: 2, lost: 1 });
  const standings = computeTeamStandings(teams, ps, [split]);
  assert.deepEqual([standings[0].teamId, standings[0].points, standings[0].matchWins, standings[1].matchWins], ["t02", 3, 2, 1]);
});

test("Team Trios, Swiss: both teams missing different seats, and a whole event with drops stays on its seats", () => {
  const teams = makeTeams(2);
  // t01 has lost seat B, t02 seat C: only the A seats meet; t01's C and t02's B have byes.
  const ps = drop(makePlayers(teams, 3), (p) => ["t01b", "t02c"].includes(p.id), 1);
  const trios = pairTeamStage("team_trios", "swiss", teams, ps, [], 2, mulberry32(7));
  assert.deepEqual(seatsOf(trios), { matches: ["t01a-t02a"], byes: ["t01c", "t02b"] });
  assert.deepEqual(trios.map((m) => m.isBye), [false, true, true]);
  // Team sealed: both teams move up, so B meets C and nobody has a bye.
  assert.deepEqual(seatsOf(pairTeamStage("team_sealed", "swiss", teams, ps, [], 2, mulberry32(7))),
                   { matches: ["t01a-t02a", "t01c-t02b"], byes: [] });
  // Whoever wins seat A takes the team match with the bye beside it: two wins to one.
  const round = play("swiss", 2, trios, (a, b) => (a < b ? a : b));
  const mine = teamRoundResults(teams, ps, [round]).get(2)!;
  assert.deepEqual([mine.get("t01")!.result, mine.get("t01")!.won, mine.get("t02")!.won], ["win", 2, 1]);

  // Nine teams, a player dropping after every round: in every round every match is seat against the same seat,
  // every active player plays or has a bye exactly once, and no bye sits beside an opponent's free same seat.
  for (const seed of [1, 2, 3, 4, 5, 6]) {
    const rng = mulberry32(900 + seed);
    const { ps: end, rounds, pairings } = teamSwiss("team_trios", 9, 3, seed, (r, all) => {
      const active = all.filter((p) => p.status === "active");
      const gone = active[Math.floor(rng() * active.length)].id;
      return drop(all, (p) => p.id === gone, r);
    });
    assert.equal(end.filter((p) => p.status === "dropped").length, rounds.length);
    let before = makePlayers(makeTeams(9), 3);
    pairings.forEach((proposed, i) => {
      const why = `seed ${seed}, round ${i + 1}`;
      for (const m of proposed.filter((x) => !x.isBye)) {
        assert.equal(m.side0ParticipantId.at(-1), m.side1ParticipantId!.at(-1), why);
        assert.notEqual(teamOfId(m.side0ParticipantId), teamOfId(m.side1ParticipantId!), why);
      }
      const seated = proposed.flatMap((m) => [m.side0ParticipantId, ...(m.side1ParticipantId ? [m.side1ParticipantId] : [])]);
      assert.deepEqual([...seated].sort(), before.filter((p) => p.status === "active").map((p) => p.id).sort(), why);
      before = before.map((p) => end.find((x) => x.id === p.id && x.droppedInRound != null && x.droppedInRound <= i + 1) ?? p);
    });
  }
});

test("Team Trios, semifinal: seat B dropped on a seed, both teams missing different seats, and no seat meeting at all", () => {
  const { teams, rounds, total, top, ...rest } = scripted("team_trios");
  const [one, four] = [top[0], top[3]];
  // Seat B of seed 1 has dropped: A v A, C v C, and seed 4's seat B has the bye, on the last table.
  let ps = drop(rest.ps, (p) => p.id === `${one}b`, total);
  let sf = pairTeamStage("team_trios", "semifinal", teams, ps, rounds, total + 1);
  assert.deepEqual(sf, pairTeamPlayoff("semifinal", teams, ps, rounds, true));
  assert.deepEqual(sf.filter((m) => [one, four].includes(teamOfId(m.side0ParticipantId))).map((m) => [m.tableNumber, m.side0ParticipantId, m.side1ParticipantId]),
                   [[1, `${one}a`, `${four}a`], [2, `${one}c`, `${four}c`], [6, `${four}b`, null]]);
  // 1–1 at the tables plus the bye: seed 4 wins 2–1. Seed 1 needs both of its matches.
  const split = play("semifinal", total + 1, sf, (a, b) => (a === `${one}c` ? b : a));
  let m = teamPlayoffMatches(teams, ps, [...rounds, split])[0];
  assert.deepEqual([m.teamIds, m.seeds, m.wins, m.winner, m.matches.length], [[one, four], [1, 4], [1, 2], four, 3]);
  assert.equal(teamPlayoffMatches(teams, ps, [...rounds, play("semifinal", total + 1, sf, (a) => a)])[0].winner, one);
  // Team sealed with the same drop is unchanged: seed 1's seat C moves up to play seat B, and seat C has the bye.
  assert.deepEqual(pairTeamStage("team_sealed", "semifinal", teams, ps, rounds, total + 1)
    .filter((x) => [one, four].includes(teamOfId(x.side0ParticipantId))).map((x) => [x.tableNumber, x.side0ParticipantId, x.side1ParticipantId]),
                   [[1, `${one}a`, `${four}a`], [2, `${one}c`, `${four}b`], [6, `${four}c`, null]]);

  // Both teams missing different seats: seed 1 has no B, seed 4 no C. Only the A seats meet; a bye each.
  ps = drop(ps, (p) => p.id === `${four}c`, total);
  sf = pairTeamStage("team_trios", "semifinal", teams, ps, rounds, total + 1);
  assert.deepEqual(sf.filter((x) => [one, four].includes(teamOfId(x.side0ParticipantId))).map((x) => [x.side0ParticipantId, x.side1ParticipantId]),
                   [[`${one}a`, `${four}a`], [`${four}b`, null], [`${one}c`, null]]);
  const lower = play("semifinal", total + 1, sf, (_a, b) => b);
  m = teamPlayoffMatches(teams, ps, [...rounds, lower])[0];
  assert.deepEqual([m.wins, m.winner, m.matches.map((x) => x.isBye)], [[1, 2], four, [false, true, true]]);
  assert.deepEqual(pairTeamStage("team_sealed", "semifinal", teams, ps, rounds, total + 1)
    .filter((x) => [one, four].includes(teamOfId(x.side0ParticipantId))).map((x) => [x.side0ParticipantId, x.side1ParticipantId]),
                   [[`${one}a`, `${four}a`], [`${one}c`, `${four}b`]]);

  // No seat meets: seed 1 is down to seat A, seed 4 to seat B. A bye each, level, so the higher seed goes on; the
  // seeds are still read back right with no table between the two teams, and the final is seat against seat.
  ps = drop(ps, (p) => [`${one}c`, `${four}a`].includes(p.id), total);
  sf = pairTeamStage("team_trios", "semifinal", teams, ps, rounds, total + 1);
  assert.deepEqual(sf.filter((x) => [one, four].includes(teamOfId(x.side0ParticipantId))).map((x) => [x.side0ParticipantId, x.side1ParticipantId, x.isBye]),
                   [[`${one}a`, null, true], [`${four}b`, null, true]]);
  const semis = play("semifinal", total + 1, sf, (a) => a);
  const after = [...rounds, semis];
  assert.deepEqual([...teamSeeds(teams, ps, after)].sort((a, b) => a[1] - b[1]).map(([id]) => id), top);
  const played = teamPlayoffMatches(teams, ps, after);
  assert.deepEqual(played.map((x) => [x.teamIds, x.seeds, x.wins, x.winner]), [[[one, four], [1, 4], [1, 1], one], [[top[1], top[2]], [2, 3], [3, 0], top[1]]]);
  const fin = pairTeamStage("team_trios", "final", teams, ps, after, total + 2);
  assert.deepEqual(fin.map((x) => [x.side0ParticipantId, x.side1ParticipantId]), [[`${one}a`, `${top[1]}a`], [`${top[1]}b`, null], [`${top[1]}c`, null]]);
  after.push(play("final", total + 2, fin, (a) => a));
  assert.deepEqual(computeTeamStandings(teams, ps, after).slice(0, 4).map((t) => [t.teamId, t.playoff]),
                   [[top[1], "winner"], [one, "final"], [top[2], "semifinal"], [four, "semifinal"]]);
  // Every member still takes the team's place, dropped or not.
  const rows = placementRows(ps, after, teams, true);
  assert.deepEqual(["a", "b", "c"].map((x) => rows.find((r) => r.participant_id === `${one}${x}`)!.place), [2, 2, 2]);

  // The same with seeds 2 and 3 as the pair no seat joins, and with both pairs: the seeds still read back right.
  const [two, three] = [top[1], top[2]];
  const other = drop(rest.ps, (p) => p.teamId === two ? p.teamSlot !== 1 : p.teamId === three && p.teamSlot !== 2, total);
  const sf23 = play("semifinal", total + 1, pairTeamStage("team_trios", "semifinal", teams, other, rounds, total + 1), (_a, b) => b);
  assert.deepEqual(sf23.matches.map((x) => x.isBye), [false, false, false, true, true]);
  assert.deepEqual([...teamSeeds(teams, other, [...rounds, sf23])].sort((a, b) => a[1] - b[1]).map(([id]) => id), top);
  assert.deepEqual(teamPlayoffMatches(teams, other, [...rounds, sf23]).map((x) => [x.teamIds, x.wins, x.winner]),
                   [[[one, four], [0, 3], four], [[two, three], [1, 1], two]]);
  const both = drop(other, (p) => p.teamId === one ? p.teamSlot !== 3 : p.teamId === four && p.teamSlot !== 1, total);
  const sfNone = play("semifinal", total + 1, pairTeamStage("team_trios", "semifinal", teams, both, rounds, total + 1), (a) => a);
  assert.ok(sfNone.matches.length === 4 && sfNone.matches.every((x) => x.isBye));
  assert.deepEqual([...teamSeeds(teams, both, [...rounds, sfNone])].sort((a, b) => a[1] - b[1]).map(([id]) => id), top);
  assert.deepEqual(teamPlayoffMatches(teams, both, [...rounds, sfNone]).map((x) => x.winner), [one, two]);
});
