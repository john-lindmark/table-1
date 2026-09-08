import { describe, expect, it } from "vitest";
import { computeStandings, buildRecords, MIN_PERCENTAGE } from "./standings";
import { byeCounts, mulberry32, pairRound, previousOpponents, recommendedRounds } from "./pairings";
import type { Match, Participant, RoundWithMatches } from "./types";

let seq = 0;
const uid = (p: string) => `${p}-${++seq}`;

function player(name: string, status: Participant["status"] = "active"): Participant {
  return {
    id: name,
    eventId: "e1",
    podId: "pod1",
    displayName: name,
    seat: null,
    status,
    droppedInRound: null,
  };
}

function match(a: string, aWins: number, b: string, bWins: number, draws = 0): Match {
  const id = uid("m");
  return {
    id,
    eventId: "e1",
    roundId: "r",
    tableNumber: null,
    isBye: false,
    gameDraws: draws,
    intentionalDraw: false,
    status: "confirmed",
    sides: [
      { id: uid("s"), matchId: id, participantId: a, side: 0, gameWins: aWins },
      { id: uid("s"), matchId: id, participantId: b, side: 1, gameWins: bWins },
    ],
  };
}

function bye(a: string): Match {
  const id = uid("m");
  return {
    id,
    eventId: "e1",
    roundId: "r",
    tableNumber: null,
    isBye: true,
    gameDraws: 0,
    intentionalDraw: false,
    status: "confirmed",
    sides: [{ id: uid("s"), matchId: id, participantId: a, side: 0, gameWins: 2 }],
  };
}

function round(number: number, matches: Match[]): RoundWithMatches {
  return {
    id: `round-${number}`,
    eventId: "e1",
    number,
    status: "recorded",
    timerDurationSeconds: 3000,
    timerRemainingAtChange: 3000,
    timerStatus: "paused",
    timerLastStartedAt: null,
    matches,
  };
}

describe("match points", () => {
  it("awards 3 for a win, 0 for a loss", () => {
    const recs = buildRecords([player("A"), player("B")], [round(1, [match("A", 2, "B", 0)])]);
    expect(recs.get("A")!.matchPoints).toBe(3);
    expect(recs.get("B")!.matchPoints).toBe(0);
  });

  it("awards 1 each for a drawn match", () => {
    const recs = buildRecords([player("A"), player("B")], [round(1, [match("A", 1, "B", 1, 1)])]);
    expect(recs.get("A")!.matchPoints).toBe(1);
    expect(recs.get("B")!.matchPoints).toBe(1);
    expect(recs.get("A")!.matchDraws).toBe(1);
  });

  it("awards 3 for a bye and scores it as a 2-0 win for game percentages", () => {
    const recs = buildRecords([player("A")], [round(1, [bye("A")])]);
    const a = recs.get("A")!;
    expect(a.matchPoints).toBe(3);
    expect(a.byes).toBe(1);
    expect(a.gamePoints).toBe(6);
    expect(a.gamesPlayed).toBe(2);
    expect(a.opponentIds).toHaveLength(0);
  });

  it("counts game points as 3 per game win and 1 per game draw", () => {
    const recs = buildRecords([player("A"), player("B")], [round(1, [match("A", 1, "B", 1, 1)])]);
    // 1 game win + 1 game draw = 3 + 1 = 4 game points across 3 games.
    expect(recs.get("A")!.gamePoints).toBe(4);
    expect(recs.get("A")!.gamesPlayed).toBe(3);
  });
});

describe("tiebreakers", () => {
  it("floors a winless player's percentages at 33%", () => {
    const standings = computeStandings(
      [player("A"), player("B")],
      [round(1, [match("A", 2, "B", 0)])],
    );
    const b = standings.find((s) => s.participantId === "B")!;
    expect(b.matchWinPct).toBeCloseTo(MIN_PERCENTAGE, 10);
    expect(b.gameWinPct).toBeCloseTo(MIN_PERCENTAGE, 10);
  });

  it("breaks a tie on game-win percentage when match points and OMW are equal", () => {
    // A beats B 2-0; C beats D 2-1. A and C both sit on 3 points with a winless
    // opponent, so the 2-0 has to rank ahead of the 2-1.
    const standings = computeStandings(
      [player("A"), player("B"), player("C"), player("D")],
      [round(1, [match("A", 2, "B", 0), match("C", 2, "D", 1)])],
    );
    expect(standings[0].participantId).toBe("A");
    expect(standings[1].participantId).toBe("C");
    expect(standings[0].gameWinPct).toBeCloseTo(1, 10);
    expect(standings[1].gameWinPct).toBeCloseTo(6 / 9, 10);
  });

  it("averages opponents' match-win percentage and excludes byes", () => {
    // A: bye in round 1, beats B in round 2. B lost both. A's only opponent is B.
    const standings = computeStandings(
      [player("A"), player("B"), player("C")],
      [
        round(1, [bye("A"), match("B", 0, "C", 2)]),
        round(2, [match("A", 2, "B", 0)]),
      ],
    );
    const a = standings.find((s) => s.participantId === "A")!;
    expect(a.opponentIds).toEqual(["B"]);
    // B played two matches, lost both: 0 points, floored to 33%.
    expect(a.opponentMatchWinPct).toBeCloseTo(MIN_PERCENTAGE, 10);
  });

  it("ranks by match points before any tiebreaker", () => {
    const standings = computeStandings(
      [player("A"), player("B"), player("C"), player("D")],
      [
        round(1, [match("A", 2, "B", 0), match("C", 2, "D", 0)]),
        round(2, [match("A", 2, "C", 0), match("B", 2, "D", 0)]),
      ],
    );
    expect(standings.map((s) => s.matchPoints)).toEqual([6, 3, 3, 0]);
    expect(standings[0].participantId).toBe("A");
    expect(standings[3].participantId).toBe("D");
  });
});

describe("pairings", () => {
  const eight = ["P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8"].map((n) => player(n));

  it("pairs everyone with no byes at an even count", () => {
    const matches = pairRound({
      participants: eight,
      rounds: [],
      roundNumber: 1,
      rng: mulberry32(42),
    });
    expect(matches).toHaveLength(4);
    expect(matches.some((m) => m.isBye)).toBe(false);
    const paired = matches.flatMap((m) => [m.side0ParticipantId, m.side1ParticipantId]);
    expect(new Set(paired).size).toBe(8);
  });

  it("never repeats a pairing across a full three-round event", () => {
    const rounds: RoundWithMatches[] = [];
    for (let n = 1; n <= 3; n++) {
      const proposed = pairRound({
        participants: eight,
        rounds,
        roundNumber: n,
        rng: mulberry32(7 + n),
      });
      const played = previousOpponents(rounds);
      for (const m of proposed) {
        if (!m.side1ParticipantId) continue;
        const key = [m.side0ParticipantId, m.side1ParticipantId].sort().join("|");
        expect(played.has(key)).toBe(false);
      }
      // Higher seed wins every match, which is the worst case for rematches.
      rounds.push(
        round(
          n,
          proposed.map((m) =>
            m.isBye ? bye(m.side0ParticipantId) : match(m.side0ParticipantId, 2, m.side1ParticipantId!, 0),
          ),
        ),
      );
    }
    expect(rounds).toHaveLength(3);
  });

  it("gives exactly one bye at an odd count and never the same player twice", () => {
    const seven = eight.slice(0, 7);
    const rounds: RoundWithMatches[] = [];
    const byeRecipients: string[] = [];
    for (let n = 1; n <= 3; n++) {
      const proposed = pairRound({
        participants: seven,
        rounds,
        roundNumber: n,
        rng: mulberry32(99 + n),
      });
      const byes = proposed.filter((m) => m.isBye);
      expect(byes).toHaveLength(1);
      byeRecipients.push(byes[0].side0ParticipantId);
      rounds.push(
        round(
          n,
          proposed.map((m) =>
            m.isBye ? bye(m.side0ParticipantId) : match(m.side0ParticipantId, 2, m.side1ParticipantId!, 1),
          ),
        ),
      );
    }
    expect(new Set(byeRecipients).size).toBe(3);
    expect(byeCounts(rounds).size).toBe(3);
  });

  it("leaves dropped players out of pairings but keeps their results in tiebreakers", () => {
    const roster = [player("A"), player("B"), player("C"), player("D", "dropped")];
    const history = [round(1, [match("A", 2, "D", 0), match("B", 2, "C", 1)])];
    const proposed = pairRound({
      participants: roster,
      rounds: history,
      roundNumber: 2,
      rng: mulberry32(3),
    });
    const involved = proposed.flatMap((m) => [m.side0ParticipantId, m.side1ParticipantId]);
    expect(involved).not.toContain("D");

    const standings = computeStandings(roster, history);
    const a = standings.find((s) => s.participantId === "A")!;
    expect(a.opponentIds).toEqual(["D"]);
  });

  it("is deterministic for a given seed", () => {
    const one = pairRound({ participants: eight, rounds: [], roundNumber: 1, rng: mulberry32(5) });
    const two = pairRound({ participants: eight, rounds: [], roundNumber: 1, rng: mulberry32(5) });
    expect(one).toEqual(two);
  });
});

describe("recommended rounds", () => {
  it("uses three rounds for a single eight-player pod", () => {
    expect(recommendedRounds(8)).toBe(3);
    expect(recommendedRounds(7)).toBe(3);
    expect(recommendedRounds(16)).toBe(4);
    expect(recommendedRounds(32)).toBe(5);
  });
});
