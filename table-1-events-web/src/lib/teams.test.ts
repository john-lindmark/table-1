import { describe, expect, it } from "vitest";
import { acrossTheTable, podSizes, seatDraft, seatTeamDraft, passDirection } from "./seating";
import { mulberry32, pairRound, type ProposedMatch } from "./pairings";
import { bracket, nextStep, playoffStandings, swissRounds, type Stage, type StagedRound } from "./playoffs";
import {
  activeTeams, computeTeamStandings, isTeamEvent, isTeamSwiss, nextTeamStage, pairsBySeat, pairTeamDraftRound, pairTeamPlayoff,
  pairTeamStage, pairTeamSwissRound, teamBracket, teamClinch, teamCutProblem, teamPlayoffMatches, teamProblems, teamRoundResults,
  teamSeeds, teamSwissStandings, type Team,
} from "./teams";
import type { Match, Participant, RoundWithMatches } from "./types";

let seq = 0;
const uid = (p: string) => `${p}-${++seq}`;

function p(name: string, extra: Partial<Participant> = {}): Participant {
  return { id: name, eventId: "e1", podId: "pod1", displayName: name, seat: null, status: "active", droppedInRound: null, ...extra };
}
function match(a: string, aWins: number, b: string, bWins: number, status: Match["status"] = "confirmed"): Match {
  const id = uid("m");
  return {
    id, eventId: "e1", roundId: "r", tableNumber: null, isBye: false, gameDraws: 0, intentionalDraw: false, status,
    sides: [
      { id: uid("s"), matchId: id, participantId: a, side: 0, gameWins: aWins },
      { id: uid("s"), matchId: id, participantId: b, side: 1, gameWins: bWins },
    ],
  };
}
function bye(a: string): Match {
  const id = uid("m");
  return { id, eventId: "e1", roundId: "r", tableNumber: null, isBye: true, gameDraws: 0, intentionalDraw: false, status: "confirmed",
    sides: [{ id: uid("s"), matchId: id, participantId: a, side: 0, gameWins: 2 }] };
}
function round(number: number, matches: Match[]): RoundWithMatches {
  return { id: `r${number}`, eventId: "e1", number, status: "recorded", timerDurationSeconds: 3000, timerRemainingAtChange: 3000,
    timerStatus: "paused", timerLastStartedAt: null, matches };
}
const pairsOf = (ms: { side0ParticipantId: string; side1ParticipantId: string | null; isBye: boolean }[]) =>
  ms.filter((m) => !m.isBye).map((m) => [m.side0ParticipantId, m.side1ParticipantId]);

describe("draft seating", () => {
  it("splits big events into near-equal pods of up to 8", () => {
    expect(podSizes(8)).toEqual([8]);
    expect(podSizes(10)).toEqual([5, 5]);
    expect(podSizes(17)).toEqual([6, 6, 5]);
    expect(podSizes(24)).toEqual([8, 8, 8]);
  });

  it("seats everyone once", () => {
    const ids = Array.from({ length: 13 }, (_, i) => `p${i}`);
    const seats = seatDraft(ids, mulberry32(4));
    expect(new Set(seats.map((s) => s.participantId)).size).toBe(13);
    expect(seats.filter((s) => s.podIndex === 0).map((s) => s.seat)).toEqual([1, 2, 3, 4, 5, 6, 7]);
  });

  it("pairs across the table in round 1", () => {
    const pod = [1, 2, 3, 4, 5, 6, 7, 8].map((n) => ({ participantId: `s${n}`, podId: "x", seat: n }));
    expect(acrossTheTable(pod).pairs).toEqual([["s1", "s5"], ["s2", "s6"], ["s3", "s7"], ["s4", "s8"]]);
    const odd = acrossTheTable(pod.slice(0, 7));
    expect(odd.bye).toBe("s7");
    expect(odd.pairs).toEqual([["s1", "s4"], ["s2", "s5"], ["s3", "s6"]]);
  });

  it("uses seats for round 1 of a draft, and table numbers run pod by pod", () => {
    const people = [
      ...[1, 2, 3, 4].map((n) => p(`a${n}`, { podId: "podA", seat: n })),
      ...[1, 2, 3, 4].map((n) => p(`b${n}`, { podId: "podB", seat: n })),
    ];
    const ms = pairRound({ participants: people, rounds: [], roundNumber: 1, draftSeating: true, podOrder: ["podA", "podB"] });
    expect(pairsOf(ms)).toEqual([["a1", "a3"], ["a2", "a4"], ["b1", "b3"], ["b2", "b4"]]);
    expect(ms.map((m) => m.tableNumber)).toEqual([1, 2, 3, 4]);
  });

  it("alternates teams around a team-draft table", () => {
    expect(seatTeamDraft(["A1", "A2", "A3"], ["B1", "B2", "B3"]).map((s) => s.participantId))
      .toEqual(["A1", "B1", "A2", "B2", "A3", "B3"]);
    expect(passDirection(1)).toBe("left");
    expect(passDirection(2)).toBe("right");
  });
});

describe("team draft pairings", () => {
  const A = ["A1", "A2", "A3"].map((n, i) => p(n, { teamId: "A", teamSlot: i + 1 }));
  const B = ["B1", "B2", "B3"].map((n, i) => p(n, { teamId: "B", teamSlot: i + 1 }));

  it("round 1 is across the alternating table (3v3)", () => {
    // Seats A1 B1 A2 B2 A3 B3: across from A1 (seat 1) is seat 4, B2.
    expect(pairsOf(pairTeamDraftRound(A, B, 1))).toEqual([["A1", "B2"], ["A2", "B3"], ["A3", "B1"]]);
  });

  it("meets every member of the other team once over 3 rounds", () => {
    const seen = new Set<string>();
    for (let r = 1; r <= 3; r++) for (const [a, b] of pairsOf(pairTeamDraftRound(A, B, r))) seen.add(`${a}${b}`);
    expect(seen.size).toBe(9);
  });

  it("never pairs teammates in a 4v4 round 1", () => {
    const A4 = [...A, p("A4", { teamId: "A", teamSlot: 4 })];
    const B4 = [...B, p("B4", { teamId: "B", teamSlot: 4 })];
    for (const [a, b] of pairsOf(pairTeamDraftRound(A4, B4, 1))) expect(a![0]).not.toBe(b![0]);
  });

  it("gives a bye when a team is a player short", () => {
    const ms = pairTeamDraftRound(A, B.slice(0, 2), 1);
    expect(ms.filter((m) => m.isBye)).toHaveLength(1);
  });
});

describe("team standings", () => {
  const teams: Team[] = [{ id: "A", name: "Alpha", order: 1 }, { id: "B", name: "Bravo", order: 2 }];
  const A = ["A1", "A2", "A3"].map((n, i) => p(n, { teamId: "A", teamSlot: i + 1 }));
  const B = ["B1", "B2", "B3"].map((n, i) => p(n, { teamId: "B", teamSlot: i + 1 }));
  const people = [...A, ...B];

  it("a team wins the round with 2 of 3, and individual wins still count", () => {
    const rounds = [round(1, [match("A1", 2, "B2", 0), match("A2", 2, "B3", 1), match("A3", 0, "B1", 2)])];
    const st = computeTeamStandings(teams, people, rounds);
    expect(st[0]).toMatchObject({ teamId: "A", points: 3, wins: 1, matchWins: 2 });
    expect(st[1]).toMatchObject({ teamId: "B", points: 0, losses: 1, matchWins: 1 });
    expect(st[1].members.find((m) => m.participantId === "B1")?.matchWins).toBe(1);
  });

  it("2–2 with teams of four is a team draw", () => {
    const A4 = [...A, p("A4", { teamId: "A", teamSlot: 4 })];
    const B4 = [...B, p("B4", { teamId: "B", teamSlot: 4 })];
    const rounds = [round(1, [match("A1", 2, "B1", 0), match("A2", 2, "B2", 0), match("A3", 0, "B3", 2), match("A4", 1, "B4", 2)])];
    const st = computeTeamStandings(teams, [...A4, ...B4], rounds);
    expect(st.map((s) => s.points)).toEqual([1, 1]);
    // Same points and match wins: game-win % decides (A 5-4 in games... B 6-5)
    expect(st.every((s) => s.draws === 1)).toBe(true);
  });

  it("a team match isn't counted until every match is in", () => {
    const rounds = [round(1, [match("A1", 2, "B2", 0), match("A2", 2, "B3", 1), match("A3", 0, "B1", 0, "pending")])];
    expect(computeTeamStandings(teams, people, rounds).map((s) => s.points)).toEqual([0, 0]);
  });

  it("team points outrank individual match wins", () => {
    const rounds = [
      round(1, [match("A1", 2, "B2", 0), match("A2", 2, "B3", 0), match("A3", 0, "B1", 2)]),
      round(2, [match("A1", 0, "B1", 2), match("A2", 0, "B2", 2), match("A3", 2, "B3", 0)]),
    ];
    const st = computeTeamStandings(teams, people, rounds);
    expect(st.map((s) => s.points)).toEqual([3, 3]);
  });
});

describe("team sealed (Swiss between teams)", () => {
  const mk = (t: string) => [1, 2, 3].map((s) => p(`${t}${s}`, { teamId: t, teamSlot: s }));
  const teams: Team[] = ["A", "B", "C", "D", "E"].map((id, i) => ({ id, name: id, order: i }));
  const people = teams.flatMap((t) => mk(t.id));

  it("pairs seat A vs A, gives a whole team the bye when odd", () => {
    const ms = pairTeamSwissRound(teams, people, [], 1, mulberry32(9));
    const real = ms.filter((m) => !m.isBye);
    expect(real).toHaveLength(6);
    for (const m of real) expect(m.side0ParticipantId.slice(1)).toBe(m.side1ParticipantId!.slice(1));
    const byeTeams = new Set(ms.filter((m) => m.isBye).map((m) => m.side0ParticipantId[0]));
    expect(byeTeams.size).toBe(1);
  });

  it("avoids rematching teams and rotates the team bye", () => {
    const r1 = pairTeamSwissRound(teams, people, [], 1, mulberry32(9));
    const played = round(1, r1.map((m) => (m.isBye ? bye(m.side0ParticipantId) : match(m.side0ParticipantId, 2, m.side1ParticipantId!, 0))));
    const r2 = pairTeamSwissRound(teams, people, [played], 2, mulberry32(9));
    const key = (a: string, b: string) => [a[0], b[0]].sort().join("");
    const before = new Set(r1.filter((m) => !m.isBye).map((m) => key(m.side0ParticipantId, m.side1ParticipantId!)));
    for (const m of r2.filter((m) => !m.isBye)) expect(before.has(key(m.side0ParticipantId, m.side1ParticipantId!))).toBe(false);
    const bye1 = r1.find((m) => m.isBye)!.side0ParticipantId[0];
    const bye2 = r2.find((m) => m.isBye)!.side0ParticipantId[0];
    expect(bye2).not.toBe(bye1);
  });

  it("explains what's missing before pairing", () => {
    expect(teamProblems(teams, [...people, p("Z1")], 3, "team_sealed")).toMatch(/isn't on a team/);
    expect(teamProblems(teams.slice(0, 3), people.filter((x) => "ABC".includes(x.teamId!)), 3, "team_draft")).toMatch(/exactly two/);
    expect(teamProblems(teams, people, 3, "team_sealed")).toBeNull();
  });
});

describe("team members ranked by their own record", () => {
  const teams: Team[] = [{ id: "A", name: "Alpha", order: 1 }, { id: "B", name: "Bravo", order: 2 }];
  const A = ["A1", "A2", "A3"].map((n, i) => p(n, { teamId: "A", teamSlot: i + 1 }));
  const B = ["B1", "B2", "B3"].map((n, i) => p(n, { teamId: "B", teamSlot: i + 1 }));

  it("3-0 with 2-0 2-1 2-1 ranks above 3-0 with 2-1 2-1 2-1, and a 1-2 below both", () => {
    // A1 and A3 both go 3-0 against the same three opponents (equal OMW); A3 gave up one game fewer.
    const rounds = [
      round(1, [match("A1", 2, "B1", 1), match("A2", 0, "B2", 2), match("A3", 2, "B3", 0)]),
      round(2, [match("A1", 2, "B2", 1), match("A2", 2, "B3", 0), match("A3", 2, "B1", 1)]),
      round(3, [match("A1", 2, "B3", 1), match("A2", 0, "B1", 2), match("A3", 2, "B2", 1)]),
    ];
    const alpha = computeTeamStandings(teams, [...A, ...B], rounds).find((t) => t.teamId === "A")!;
    expect(alpha.members.map((m) => m.participantId)).toEqual(["A3", "A1", "A2"]);
    expect(alpha.members.map((m) => `${m.matchWins}-${m.matchLosses}`)).toEqual(["3-0", "3-0", "1-2"]);
  });

  it("equal records and game wins: higher OMW first, then seat letter", () => {
    const rounds = [round(1, [match("A1", 2, "B1", 0), match("A2", 2, "B2", 0), match("A3", 0, "B3", 0, "pending")]),
                    round(2, [match("B1", 2, "B3", 0)])];
    const alpha = computeTeamStandings(teams, [...A, ...B], rounds).find((t) => t.teamId === "A")!;
    // A1 beat B1 (1-1 after round 2), A2 beat B2 (0-1): A1's opponents did better.
    expect(alpha.members.map((m) => m.participantId)).toEqual(["A1", "A2", "A3"]);
  });
});

describe("team clinch", () => {
  const teams: Team[] = [{ id: "A", name: "Alpha", order: 1 }, { id: "B", name: "Bravo", order: 2 }];
  const A = ["A1", "A2", "A3"].map((n, i) => p(n, { teamId: "A", teamSlot: i + 1 }));
  const B = ["B1", "B2", "B3"].map((n, i) => p(n, { teamId: "B", teamSlot: i + 1 }));
  const people = [...A, ...B];
  const r1 = round(1, [match("A1", 2, "B2", 0), match("A2", 2, "B3", 1), match("A3", 2, "B1", 1)]);

  it("3v3 over three rounds: 5 match wins clinches with matches still open", () => {
    const r2 = round(2, [match("A1", 2, "B3", 0), match("A2", 2, "B1", 0), match("A3", 0, "B2", 0, "pending")]);
    expect(teamClinch(teams, people, [r1, r2], 3)).toEqual({
      teamId: "A", name: "Alpha", matchWins: 5, opponentMatchWins: 0, remaining: 4,
    });
  });

  it("4 of 9 isn't enough", () => {
    const r2 = round(2, [match("A1", 2, "B3", 0), match("A2", 0, "B1", 0, "pending"), match("A3", 0, "B2", 0, "pending")]);
    expect(teamClinch(teams, people, [r1, r2], 3)).toBeNull();
  });

  it("4v4 over three rounds needs 7 of 12", () => {
    const A4 = [...A, p("A4", { teamId: "A", teamSlot: 4 })];
    const B4 = [...B, p("B4", { teamId: "B", teamSlot: 4 })];
    const four = [...A4, ...B4];
    const w1 = round(1, [match("A1", 2, "B1", 0), match("A2", 2, "B2", 0), match("A3", 2, "B3", 0), match("A4", 2, "B4", 0)]);
    const six = round(2, [match("A1", 2, "B2", 0), match("A2", 2, "B3", 0), match("A3", 0, "B4", 0, "pending"), match("A4", 0, "B1", 0, "pending")]);
    expect(teamClinch(teams, four, [w1, six], 3)).toBeNull();
    const seven = round(2, [match("A1", 2, "B2", 0), match("A2", 2, "B3", 0), match("A3", 2, "B4", 0), match("A4", 0, "B1", 0, "pending")]);
    expect(teamClinch(teams, four, [w1, seven], 3)?.matchWins).toBe(7);
  });

  it("nothing left to play, or more than two teams: no clinch", () => {
    const r2 = round(2, [match("A1", 2, "B3", 0), match("A2", 2, "B1", 0), match("A3", 2, "B2", 0)]);
    const r3 = round(3, [match("A1", 2, "B1", 0), match("A2", 2, "B2", 0), match("A3", 2, "B3", 0)]);
    expect(teamClinch(teams, people, [r1, r2, r3], 3)).toBeNull();
    const C = ["C1", "C2", "C3"].map((n, i) => p(n, { teamId: "C", teamSlot: i + 1 }));
    expect(teamClinch([...teams, { id: "C", name: "Charlie", order: 3 }], [...people, ...C], [r1, r2], 3)).toBeNull();
  });
});

// ── Team Trios and the top 4 between teams (the engine's teams.test.ts runs the same events under Deno) ─────────

const LETTERS = "abcd";
const makeTeams = (n: number): Team[] =>
  Array.from({ length: n }, (_, i) => ({ id: `t${String(i + 1).padStart(2, "0")}`, name: `Team ${String.fromCharCode(65 + i)}`, order: i }));
const makePlayers = (teams: Team[], size: number): Participant[] =>
  teams.flatMap((t) => Array.from({ length: size }, (_, i) => p(`${t.id}${LETTERS[i]}`, { teamId: t.id, teamSlot: i + 1 })));
const teamOfId = (id: string) => id.slice(0, 3);
const dropWhere = (ps: Participant[], gone: (x: Participant) => boolean, r: number): Participant[] =>
  ps.map((x) => (gone(x) ? { ...x, status: "dropped" as const, droppedInRound: r } : x));

function playStage(stage: Stage, number: number, proposed: ProposedMatch[], winner: (a: string, b: string, table: number) => string): StagedRound {
  return {
    ...round(number, proposed.map((m) => {
      if (m.isBye) return { ...bye(m.side0ParticipantId), tableNumber: m.tableNumber };
      const w = winner(m.side0ParticipantId, m.side1ParticipantId!, m.tableNumber);
      return { ...match(m.side0ParticipantId, w === m.side0ParticipantId ? 2 : 1, m.side1ParticipantId!, w === m.side1ParticipantId ? 2 : 1),
               tableNumber: m.tableNumber };
    })),
    stage,
  };
}

function teamSwiss(format: string, count: number, size: number, seed: number,
                   afterRound: (r: number, ps: Participant[]) => Participant[] = (_r, ps) => ps) {
  const rng = mulberry32(seed);
  const teams = makeTeams(count);
  let ps = makePlayers(teams, size);
  const rounds: StagedRound[] = [];
  const total = swissRounds(count);
  const pairings: ProposedMatch[][] = [];
  for (let r = 1; r <= total; r++) {
    const proposed = pairTeamStage(format, "swiss", teams, ps, rounds, r, rng);
    pairings.push(proposed);
    rounds.push(playStage("swiss", r, proposed, (a, b) => (rng() < 0.5 ? a : b)));
    ps = afterRound(r, ps);
  }
  return { teams, ps, rounds, total, rng, pairings };
}

/** Worked out here from the played round: more seats won (byes count); level goes to `hi`. */
function teamWinner(played: StagedRound, hi: string, lo: string): string {
  let a = 0, b = 0;
  for (const m of played.matches) {
    const sides = m.sides.filter((x) => x.participantId);
    if (!sides.every((x) => [hi, lo].includes(teamOfId(x.participantId!)))) continue;
    const won = m.isBye ? sides[0] : sides[0].gameWins > sides[1].gameWins ? sides[0] : sides[1];
    if (teamOfId(won.participantId!) === hi) a++; else b++;
  }
  return b > a ? lo : hi;
}

describe("Team Trios", () => {
  it("is a team event paired as Swiss between teams, never a draft pairing", () => {
    expect(["team_draft", "team_sealed", "team_trios", "sealed", "modern", null].map(isTeamEvent)).toEqual([true, true, true, false, false, false]);
    expect(["team_draft", "team_sealed", "team_trios", "draft"].map(isTeamSwiss)).toEqual([false, true, true, false]);
    const teams = makeTeams(6);
    expect(teamProblems(teams, makePlayers(teams, 3), 3, "team_trios")).toBeNull();
  });

  it("pairs and ranks exactly as team sealed does for the same results (full teams)", () => {
    for (const count of [2, 3, 5, 6, 8, 11]) {
      const sealed = teamSwiss("team_sealed", count, 3, 40 + count);
      const trios = teamSwiss("team_trios", count, 3, 40 + count);
      expect(trios.pairings, `${count} teams`).toEqual(sealed.pairings);
      for (const m of sealed.pairings[0].filter((x) => !x.isBye)) expect(m.side0ParticipantId.at(-1)).toBe(m.side1ParticipantId!.at(-1));
      expect(computeTeamStandings(trios.teams, trios.ps, trios.rounds).map((t) => [t.teamId, t.rank, t.points, t.matchWins, t.gameWinPct]))
        .toEqual(computeTeamStandings(sealed.teams, sealed.ps, sealed.rounds).map((t) => [t.teamId, t.rank, t.points, t.matchWins, t.gameWinPct]));
      expect(nextTeamStage("team_trios", trios.teams, trios.ps, trios.rounds, trios.total, 4))
        .toBe(nextTeamStage("team_sealed", sealed.teams, sealed.ps, sealed.rounds, sealed.total, 4));
    }
  });
});

describe("team top 4", () => {
  it("5 to 12 teams of 3 and of 4: seeds 1v4 and 2v3, the team final, final places, members' Swiss records", () => {
    for (const size of [3, 4]) {
      for (let count = 5; count <= 12; count++) {
        const format = size === 3 && count % 2 ? "team_trios" : "team_sealed";
        const { teams, ps, rounds, total, rng } = teamSwiss(format, count, size, count * 100 + size * 10 + 1);
        const why = `${count} teams of ${size}`;
        const swiss = teamSwissStandings(teams, ps, rounds);
        const top = swiss.slice(0, 4).map((t) => t.teamId);
        expect(nextStep({ stages: rounds.map((r) => r.stage!), waiting: false, numberOfRounds: total, topCut: 4,
                          activePlayers: ps.length, activeTeams: activeTeams(teams, ps).length }), why).toBe("cut4");
        expect(nextTeamStage(format, teams, ps, rounds, total, 4), why).toBe("semifinal");
        expect(nextTeamStage(format, teams, ps, rounds, total, 0), why).toBeNull();

        const sf = pairTeamStage(format, "semifinal", teams, ps, rounds, total + 1);
        const want = [[top[0], top[3]], [top[1], top[2]]].flatMap(([hi, lo]) =>
          Array.from({ length: size }, (_, i) => [`${hi}${LETTERS[i]}`, `${lo}${LETTERS[i]}`, false]));
        expect(sf.map((m) => [m.side0ParticipantId, m.side1ParticipantId, m.isBye]), why).toEqual(want);
        expect(sf.map((m) => m.tableNumber), why).toEqual(Array.from({ length: 2 * size }, (_, i) => i + 1));

        // Teams of 4: the first semifinal is split 2–2 and goes to the higher seed.
        const split = size === 4;
        const semis = playStage("semifinal", total + 1, sf, (a, b, table) => (split && table <= 4 ? (table <= 2 ? b : a) : rng() < 0.5 ? a : b));
        rounds.push(semis);
        const w1 = teamWinner(semis, top[0], top[3]), w2 = teamWinner(semis, top[1], top[2]);
        if (split) expect(w1, why).toBe(top[0]);
        expect(teamPlayoffMatches(teams, ps, rounds).map((m) => [m.stage, m.teamIds, m.seeds, m.winner]), why).toEqual([
          ["semifinal", [top[0], top[3]], [1, 4], w1], ["semifinal", [top[1], top[2]], [2, 3], w2],
        ]);
        // A whole beaten team dropping afterwards moves no seed.
        const loser1 = w1 === top[0] ? top[3] : top[0], loser2 = w2 === top[1] ? top[2] : top[1];
        const later = dropWhere(ps, (x) => x.teamId === loser1, total + 1);
        expect([...teamSeeds(teams, later, rounds)].sort((a, b) => a[1] - b[1]).map(([id]) => id), why).toEqual(top);

        expect(nextTeamStage(format, teams, later, rounds, total, 4), why).toBe("final");
        const finalists = [w1, w2].sort((a, b) => top.indexOf(a) - top.indexOf(b));
        const fin = pairTeamStage(format, "final", teams, later, rounds, total + 2);
        expect(fin.map((m) => [m.side0ParticipantId, m.side1ParticipantId]), why)
          .toEqual(Array.from({ length: size }, (_, i) => [`${finalists[0]}${LETTERS[i]}`, `${finalists[1]}${LETTERS[i]}`]));
        const final = playStage("final", total + 2, fin, (a, b) => (rng() < 0.5 ? a : b));
        rounds.push(final);
        const champion = teamWinner(final, finalists[0], finalists[1]);
        expect(nextTeamStage(format, teams, later, rounds, total, 4), why).toBeNull();

        const standings = computeTeamStandings(teams, later, rounds);
        const out = [loser1, loser2].sort((a, b) => top.indexOf(a) - top.indexOf(b));
        expect(standings.slice(0, 4).map((t) => [t.teamId, t.playoff]), why).toEqual([
          [champion, "winner"], [finalists.find((t) => t !== champion), "final"], [out[0], "semifinal"], [out[1], "semifinal"],
        ]);
        expect(standings.map((t) => t.rank), why).toEqual(standings.map((_, i) => i + 1));
        expect(standings.slice(4).map((t) => [t.teamId, t.playoff]), why).toEqual(swiss.slice(4).map((t) => [t.teamId, null]));
        for (const t of standings) {
          const was = swiss.find((x) => x.teamId === t.teamId)!;
          expect([t.swissRank, t.points, t.wins, t.matchWins], why).toEqual([was.rank, was.points, was.wins, was.matchWins]);
        }
        // The players' own standings stay Swiss; the bracket is the teams'.
        expect(playoffStandings(later, rounds).every((x) => x.playoff === null), why).toBe(true);
        expect(bracket(later, rounds), why).toEqual([]);
        const b = teamBracket(teams, later, rounds);
        expect(b.map((x) => [x.stage, x.matches.length]), why).toEqual([["semifinal", 2], ["final", 1]]);
        expect(b[0].matches.map((m) => m.sides.map((x) => [x.seed, x.team_id])), why).toEqual([[[1, top[0]], [4, top[3]]], [[2, top[1]], [3, top[2]]]]);
        expect(b[1].matches[0].winner, why).toBe(champion);
        expect(b[1].matches[0].matches).toHaveLength(size);
      }
    }
  });

  /** Six teams of 3, scripted so t01 finishes first: the lower team id wins every Swiss match. */
  function scripted(format: string) {
    const teams = makeTeams(6);
    const ps = makePlayers(teams, 3);
    const rounds: StagedRound[] = [];
    const total = swissRounds(6);
    for (let r = 1; r <= total; r++) {
      rounds.push(playStage("swiss", r, pairTeamStage(format, "swiss", teams, ps, rounds, r, mulberry32(r)), (a, b) => (a < b ? a : b)));
    }
    const top = teamSwissStandings(teams, ps, rounds).slice(0, 4).map((t) => t.teamId);
    expect(top[0]).toBe("t01");
    return { teams, ps, rounds, total, top };
  }

  it("Team Trios pairs by seat number: a dropped seat never moves the others up, in Swiss or in the semifinals", () => {
    expect(["team_trios", "team_sealed", "team_draft", null].map(pairsBySeat)).toEqual([true, false, false, false]);
    const seatsOf = (ms: ProposedMatch[]) => ({
      matches: ms.filter((m) => !m.isBye).map((m) => [m.side0ParticipantId, m.side1ParticipantId!].sort().join("-")).sort(),
      byes: ms.filter((m) => m.isBye).map((m) => m.side0ParticipantId).sort(),
    });
    // Swiss, seat B of t01 dropped: C still plays C, and t02's seat B has the bye. Team sealed is as it always was.
    const two = makeTeams(2);
    const short = dropWhere(makePlayers(two, 3), (x) => x.id === "t01b", 1);
    for (const seed of [1, 2, 3]) {
      expect(seatsOf(pairTeamStage("team_trios", "swiss", two, short, [], 2, mulberry32(seed)))).toEqual({ matches: ["t01a-t02a", "t01c-t02c"], byes: ["t02b"] });
      const sealed = pairTeamStage("team_sealed", "swiss", two, short, [], 2, mulberry32(seed));
      expect(seatsOf(sealed)).toEqual({ matches: ["t01a-t02a", "t01c-t02b"], byes: ["t02c"] });
      expect(pairTeamSwissRound(two, short, [], 2, mulberry32(seed))).toEqual(sealed);
    }
    // The bye is a match win for its team.
    const r1 = playStage("swiss", 1, pairTeamStage("team_trios", "swiss", two, short, [], 1, mulberry32(1)),
      (a, b) => ([a, b].includes("t01a") ? "t01a" : [a, b].find((id) => id.startsWith("t02"))!));
    expect(teamRoundResults(two, short, [r1]).get(1)!.get("t02")).toEqual({ result: "win", opponent: "t01", won: 2, lost: 1 });
    // Both teams missing different seats: only the A seats meet, a bye each. Team sealed moves both up.
    const both = dropWhere(short, (x) => x.id === "t02c", 1);
    expect(seatsOf(pairTeamStage("team_trios", "swiss", two, both, [], 2, mulberry32(7)))).toEqual({ matches: ["t01a-t02a"], byes: ["t01c", "t02b"] });
    expect(seatsOf(pairTeamStage("team_sealed", "swiss", two, both, [], 2, mulberry32(7)))).toEqual({ matches: ["t01a-t02a", "t01c-t02b"], byes: [] });

    // Semifinal, seat B of seed 1 dropped: A v A, C v C, seed 4's seat B has the bye on the last table.
    const { teams, rounds, total, top, ...rest } = scripted("team_trios");
    const [one, four] = [top[0], top[3]];
    const mine = (ms: ProposedMatch[]) => ms.filter((m) => [one, four].includes(teamOfId(m.side0ParticipantId)))
      .map((m) => [m.tableNumber, m.side0ParticipantId, m.side1ParticipantId]);
    let ps = dropWhere(rest.ps, (x) => x.id === `${one}b`, total);
    const sf = pairTeamStage("team_trios", "semifinal", teams, ps, rounds, total + 1);
    expect(sf).toEqual(pairTeamPlayoff("semifinal", teams, ps, rounds, true));
    expect(mine(sf)).toEqual([[1, `${one}a`, `${four}a`], [2, `${one}c`, `${four}c`], [6, `${four}b`, null]]);
    expect(mine(pairTeamStage("team_sealed", "semifinal", teams, ps, rounds, total + 1)))
      .toEqual([[1, `${one}a`, `${four}a`], [2, `${one}c`, `${four}b`], [6, `${four}c`, null]]);
    const split = playStage("semifinal", total + 1, sf, (a, b) => (a === `${one}c` ? b : a));
    expect(teamPlayoffMatches(teams, ps, [...rounds, split])[0]).toMatchObject({ teamIds: [one, four], wins: [1, 2], winner: four });
    // No seat meets (seed 1 down to seat A, seed 4 to seat B): a bye each, level, so the higher seed goes on, and
    // the seeds are still read back right.
    ps = dropWhere(ps, (x) => [`${one}c`, `${four}a`, `${four}c`].includes(x.id), total);
    const none = playStage("semifinal", total + 1, pairTeamStage("team_trios", "semifinal", teams, ps, rounds, total + 1), (a) => a);
    expect(none.matches.filter((m) => m.isBye).map((m) => m.sides[0].participantId)).toEqual([`${one}a`, `${four}b`]);
    expect([...teamSeeds(teams, ps, [...rounds, none])].sort((a, b) => a[1] - b[1]).map(([id]) => id)).toEqual(top);
    expect(teamPlayoffMatches(teams, ps, [...rounds, none]).map((m) => [m.teamIds, m.wins, m.winner]))
      .toEqual([[[one, four], [1, 1], one], [[top[1], top[2]], [3, 0], top[1]]]);
    expect(pairTeamStage("team_trios", "final", teams, ps, [...rounds, none], total + 2).map((m) => [m.side0ParticipantId, m.side1ParticipantId]))
      .toEqual([[`${one}a`, `${top[1]}a`], [`${top[1]}b`, null], [`${top[1]}c`, null]]);
  });

  it("team sealed, a short-handed seed: its seats move up, the other team's last seat has a bye that counts as a win", () => {
    const { teams, rounds, total, top, ...rest } = scripted("team_sealed");
    let ps = dropWhere(rest.ps, (x) => x.id === "t01b", total);
    const sf = pairTeamPlayoff("semifinal", teams, ps, rounds);
    expect(pairTeamStage("team_sealed", "semifinal", teams, ps, rounds, total + 1)).toEqual(sf);
    expect(sf.filter((m) => teamOfId(m.side0ParticipantId) === "t01").map((m) => [m.side0ParticipantId, m.side1ParticipantId]))
      .toEqual([["t01a", `${top[3]}a`], ["t01c", `${top[3]}b`]]);
    expect(sf.filter((m) => m.isBye).map((m) => [m.tableNumber, m.side0ParticipantId])).toEqual([[6, `${top[3]}c`]]);
    const split = playStage("semifinal", total + 1, sf, (a, b) => (a === "t01c" ? b : a));
    const m = teamPlayoffMatches(teams, ps, [...rounds, split])[0];
    expect([m.wins, m.winner]).toEqual([[1, 2], top[3]]);
    // A team with nobody left isn't seeded, and four teams left is no cut.
    const gone = dropWhere(ps, (x) => x.teamId === top[1], total);
    expect([...teamSeeds(teams, gone, rounds).keys()]).not.toContain(top[1]);
    expect(teamSeeds(teams, gone, rounds).size).toBe(4);
    const four = dropWhere(gone, (x) => x.teamId === top[2], total);
    expect(nextTeamStage("team_sealed", teams, four, rounds, total, 4)).toBeNull();
  });

  it("refuses a top 8 between teams and any cut in a team draft", () => {
    expect(teamCutProblem("team_trios", 4)).toBeNull();
    expect(teamCutProblem("team_sealed", 8)).toMatch(/top 4/);
    expect(teamCutProblem("team_draft", 4)).toMatch(/team draft has no top cut/);
    const { teams, ps, rounds, total } = teamSwiss("team_sealed", 9, 3, 30);
    expect(() => nextTeamStage("team_sealed", teams, ps, [], total, 8)).toThrow(/Team events cut to top 4/);
    expect(nextTeamStage("team_sealed", teams, ps, rounds.slice(0, 2), total, 8)).toBe("swiss");
    expect(() => nextTeamStage("team_sealed", teams, ps, rounds, total, 8)).toThrow(/Team events cut to top 4/);
    expect(() => pairTeamStage("team_trios", "quarterfinal", teams, ps, rounds, total + 1)).toThrow(/Team events cut to top 4/);
    const two = makeTeams(2);
    const six = makePlayers(two, 3);
    expect(() => nextTeamStage("team_draft", two, six, [], 3, 4)).toThrow(/team draft has no top cut/);
    expect(() => nextTeamStage("team_draft", two, six, [], 3, 8)).toThrow(/team draft has no top cut/);
    expect(() => pairTeamStage("team_draft", "semifinal", two, six, [], 4)).toThrow(/team draft has no top cut/);
    expect(nextTeamStage("team_draft", two, six, [], 3, 0)).toBe("swiss");
    expect(() => pairTeamPlayoff("final", teams, ps, rounds)).toThrow(/needs a winner/);
  });
});
