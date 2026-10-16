import { describe, expect, it } from "vitest";
import { computeStandings } from "./standings";
import { byeCounts, mulberry32, pairRound, recommendedRounds } from "./pairings";
import type { Match, Participant, RoundWithMatches } from "./types";

// Whole simulated events at store-to-RCQ sizes. Always checks the pairing rules hold at scale;
// with T1_PERF=1 (tools/test/perf.sh) also enforces time budgets. Measured 2026-10-16 on John's Mac: 512 players
// pair in ~1.3 ms, standings ~0.4 ms. Budgets sit well above that (plus first-call JIT warm-up) so they catch
// algorithmic regressions (an O(n^3) pass, a quadratic lookup), not noise.
const PERF = !!process.env.T1_PERF;
const BUDGET_MS: Record<number, { pair: number; standings: number }> = {
  8: { pair: 25, standings: 10 },
  64: { pair: 25, standings: 10 },
  256: { pair: 30, standings: 15 },
  512: { pair: 60, standings: 25 },
};

function players(n: number): Participant[] {
  return Array.from({ length: n }, (_, i) => ({
    id: `p${i}`, eventId: "e1", podId: "pod1", displayName: `P${i}`, seat: i + 1, status: "active", droppedInRound: null,
  }));
}

function playRound(number: number, proposed: ReturnType<typeof pairRound>, rng: () => number): RoundWithMatches {
  const matches: Match[] = proposed.map((m, i) => {
    const id = `r${number}m${i}`;
    if (m.isBye || !m.side1ParticipantId) {
      return { id, eventId: "e1", roundId: `r${number}`, tableNumber: m.tableNumber, isBye: true, gameDraws: 0,
        intentionalDraw: false, status: "confirmed",
        sides: [{ id: `${id}s0`, matchId: id, participantId: m.side0ParticipantId, side: 0, gameWins: 2 }] };
    }
    const outcomes: [number, number, number][] = [[2, 0, 0], [2, 1, 0], [0, 2, 0], [1, 2, 0], [1, 1, 1]];
    const [a, b, d] = outcomes[Math.floor(rng() * outcomes.length)];
    return { id, eventId: "e1", roundId: `r${number}`, tableNumber: m.tableNumber, isBye: false, gameDraws: d,
      intentionalDraw: false, status: "confirmed",
      sides: [
        { id: `${id}s0`, matchId: id, participantId: m.side0ParticipantId, side: 0, gameWins: a },
        { id: `${id}s1`, matchId: id, participantId: m.side1ParticipantId, side: 1, gameWins: b },
      ] };
  });
  return { id: `r${number}`, eventId: "e1", number, status: "recorded", timerDurationSeconds: 3000,
    timerRemainingAtChange: 3000, timerStatus: "paused", timerLastStartedAt: null, matches };
}

describe.each([8, 9, 64, 65, 256, 512])("a full Swiss event with %i players", (n) => {
  it("pairs every round legally and computes standings within budget", () => {
    const rng = mulberry32(n * 7919);
    const ps = players(n);
    const rounds: RoundWithMatches[] = [];
    const total = recommendedRounds(n);
    let worstPair = 0;
    for (let r = 1; r <= total; r++) {
      const t0 = performance.now();
      const proposed = pairRound({ participants: ps, rounds, roundNumber: r, rng });
      worstPair = Math.max(worstPair, performance.now() - t0);

      const seen = proposed.flatMap((m) => [m.side0ParticipantId, m.side1ParticipantId].filter(Boolean));
      expect(new Set(seen).size, `round ${r}: everyone paired exactly once`).toBe(n);
      expect(seen.length).toBe(n);
      expect(proposed.filter((m) => m.isBye).length, `round ${r}: byes`).toBe(n % 2);
      rounds.push(playRound(r, proposed, rng));
    }
    const byes = byeCounts(rounds);
    expect(Math.max(0, ...byes.values()), "nobody gets a second bye").toBeLessThanOrEqual(1);

    const t0 = performance.now();
    const standings = computeStandings(ps, rounds);
    const standingsMs = performance.now() - t0;
    expect(standings).toHaveLength(n);
    for (let i = 1; i < standings.length; i++) {
      expect(standings[i - 1].matchPoints).toBeGreaterThanOrEqual(standings[i].matchPoints);
    }

    const budget = BUDGET_MS[n] ?? BUDGET_MS[n - 1];
    if (PERF && budget) {
      console.log(`perf swiss n=${n}: worst pairing ${worstPair.toFixed(1)} ms (budget ${budget.pair}), standings ${standingsMs.toFixed(1)} ms (budget ${budget.standings})`);
      expect(worstPair, `pairing n=${n}`).toBeLessThan(budget.pair);
      expect(standingsMs, `standings n=${n}`).toBeLessThan(budget.standings);
    }
  });
});
