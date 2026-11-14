// Top 4 and top 8 on the web's copy of the rules (playoffs.ts is the engine's file; the engine's own
// playoffs.test.ts runs the same simulations under Deno). Shared cases: scheduledEvents.test.ts.
import { describe, expect, it } from "vitest";
import { mulberry32, pairRound, type ProposedMatch } from "./pairings";
import { computeStandings } from "./standings";
import {
  bracket, nextStage, nextStep, pairPlayoff, playoffStandings, seeds, swissRounds, type Stage, type StagedRound,
} from "./playoffs";
import type { Participant } from "./types";

const players = (n: number): Participant[] =>
  Array.from({ length: n }, (_, i) => ({
    id: `p${String(i + 1).padStart(2, "0")}`, eventId: "e", podId: "pod", displayName: `P${i + 1}`, seat: i + 1,
    status: "active", droppedInRound: null,
  }));

let ids = 0;
function play(stage: Stage, number: number, proposed: ProposedMatch[], winner: (a: string, b: string) => string): StagedRound {
  const roundId = `r${number}`;
  return {
    id: roundId, eventId: "e", number, status: "recorded", stage, timerDurationSeconds: 3000,
    timerRemainingAtChange: 3000, timerStatus: "running", timerLastStartedAt: null,
    matches: proposed.map((m) => {
      const id = `m${++ids}`;
      const w = m.isBye ? m.side0ParticipantId : winner(m.side0ParticipantId, m.side1ParticipantId!);
      return {
        id, eventId: "e", roundId, tableNumber: m.tableNumber, isBye: m.isBye, gameDraws: 0, intentionalDraw: false,
        status: "confirmed" as const,
        sides: [
          { id: `${id}a`, matchId: id, participantId: m.side0ParticipantId, side: 0 as const, gameWins: m.isBye || w === m.side0ParticipantId ? 2 : 1 },
          ...(m.side1ParticipantId ? [{ id: `${id}b`, matchId: id, participantId: m.side1ParticipantId, side: 1 as const,
            gameWins: w === m.side1ParticipantId ? 2 : 1 }] : []),
        ],
      };
    }),
  };
}

/** A Swiss event with random results; one player drops after round 1 when that still leaves a cut. */
function randomSwiss(n: number, seed: number, topCut: 4 | 8) {
  const rng = mulberry32(seed);
  let ps = players(n);
  const rounds: StagedRound[] = [];
  const total = swissRounds(n);
  for (let r = 1; r <= total; r++) {
    rounds.push(play("swiss", r, pairRound({ participants: ps, rounds, roundNumber: r, rng }), (a, b) => (rng() < 0.5 ? a : b)));
    if (r === 1 && n > topCut + 1) {
      const gone = ps[Math.floor(rng() * n)].id;
      ps = ps.map((p) => (p.id === gone ? { ...p, status: "dropped" as const, droppedInRound: 1 } : p));
    }
  }
  return { ps, rounds, total, rng, active: ps.filter((p) => p.status === "active").length };
}

function playCut(topCut: 4 | 8, ps: Participant[], rounds: StagedRound[], total: number, active: number, rng: () => number) {
  const stages: { stage: Stage; proposed: ProposedMatch[]; winners: string[] }[] = [];
  for (let next = nextStage(rounds, total, topCut, active); next; next = nextStage(rounds, total, topCut, active)) {
    const proposed = pairPlayoff(next as Exclude<Stage, "swiss">, ps, rounds, topCut);
    const round = play(next, rounds.length + 1, proposed, (a, b) => (rng() < 0.5 ? a : b));
    rounds.push(round);
    stages.push({ stage: next, proposed, winners: round.matches.map((m) => (m.sides[0].gameWins > m.sides[1].gameWins ? m.sides[0] : m.sides[1]).participantId!) });
  }
  return stages;
}

describe("top 4", () => {
  it("5 to 40 players: semifinals 1v4 and 2v3, the final, and places 1..n once each", () => {
    for (let n = 5; n <= 40; n++) {
      const { ps, rounds, total, rng, active } = randomSwiss(n, n * 100 + 1, 4);
      const why = `${n} players`;
      const swiss = computeStandings(ps, rounds);
      const top = swiss.filter((s) => s.status === "active").slice(0, 4).map((s) => s.participantId);
      expect(nextStep({ stages: rounds.map((r) => r.stage!), waiting: false, numberOfRounds: total, topCut: 4, activePlayers: active }), why).toBe("cut4");
      const stages = playCut(4, ps, rounds, total, active, rng);
      expect(stages.map((s) => s.stage), why).toEqual(["semifinal", "final"]);
      const [sf, fin] = stages;
      expect(sf.proposed.map((m) => [m.tableNumber, m.side0ParticipantId, m.side1ParticipantId]), why)
        .toEqual([[1, top[0], top[3]], [2, top[1], top[2]]]);
      const seedOf = seeds(ps, rounds);
      const finalists = [...sf.winners].sort((a, b) => seedOf.get(a)! - seedOf.get(b)!);
      expect(fin.proposed.map((m) => [m.side0ParticipantId, m.side1ParticipantId]), why).toEqual([finalists]);
      const final = playoffStandings(ps, rounds);
      const champion = fin.winners[0];
      const losers = top.filter((id) => !sf.winners.includes(id));
      expect(final.slice(0, 4).map((r) => [r.participantId, r.playoff]), why).toEqual([
        [champion, "winner"], [finalists.find((id) => id !== champion), "final"], [losers[0], "semifinal"], [losers[1], "semifinal"],
      ]);
      expect(final.map((r) => r.rank), why).toEqual(final.map((_, i) => i + 1));
      expect(new Set(final.map((r) => r.participantId)).size, why).toBe(n);
      expect(final.slice(4).map((r) => r.participantId), why)
        .toEqual(swiss.filter((s) => !top.includes(s.participantId)).map((s) => s.participantId));
      const b = bracket(ps, rounds);
      expect(b.map((s) => [s.stage, s.matches.length]), why).toEqual([["semifinal", 2], ["final", 1]]);
      expect(b[0].matches.map((m) => m.sides.map((s) => s.seed)), why).toEqual([[1, 4], [2, 3]]);
    }
  });

  it("needs 5 or more active players, has no quarterfinals, and waits for both semifinal winners", () => {
    const { ps, rounds, total } = randomSwiss(8, 4, 8);
    expect(nextStage(rounds, total, 4, 4)).toBeNull();
    expect(nextStage(rounds, total, 4, 5)).toBe("semifinal");
    expect(() => pairPlayoff("quarterfinal", ps, rounds, 4)).toThrow(/no quarterfinals/);
    expect(() => pairPlayoff("semifinal", ps.slice(0, 3), rounds, 4)).toThrow(/5 or more/);
    expect(() => pairPlayoff("final", ps, rounds, 4)).toThrow(/needs a winner/);
  });
});

describe("top 8 (unchanged)", () => {
  it("9 to 40 players: quarterfinals 1v8 4v5 2v7 3v6, then the winners by table, places 1..n once each", () => {
    for (let n = 9; n <= 40; n++) {
      const { ps, rounds, total, rng, active } = randomSwiss(n, n * 100 + 7, 8);
      const why = `${n} players`;
      const top = computeStandings(ps, rounds).filter((s) => s.status === "active").slice(0, 8).map((s) => s.participantId);
      const stages = playCut(8, ps, rounds, total, active, rng);
      expect(stages.map((s) => s.stage), why).toEqual(["quarterfinal", "semifinal", "final"]);
      expect(stages[0].proposed.map((m) => [m.side0ParticipantId, m.side1ParticipantId]), why)
        .toEqual([[top[0], top[7]], [top[3], top[4]], [top[1], top[6]], [top[2], top[5]]]);
      const final = playoffStandings(ps, rounds);
      expect(final[0].participantId, why).toBe(stages[2].winners[0]);
      expect(final.slice(0, 8).map((r) => r.playoff), why)
        .toEqual(["winner", "final", "semifinal", "semifinal", "quarterfinal", "quarterfinal", "quarterfinal", "quarterfinal"]);
      expect(final.map((r) => r.rank), why).toEqual(final.map((_, i) => i + 1));
    }
  });
});
