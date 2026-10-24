import { describe, expect, it } from "vitest";
import { acrossTheTable, podSizes, seatDraft, seatTeamDraft, passDirection } from "./seating";
import { mulberry32, pairRound } from "./pairings";
import { computeTeamStandings, pairTeamDraftRound, pairTeamSwissRound, teamClinch, teamProblems, type Team } from "./teams";
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
