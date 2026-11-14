// Top 8, top 4 and automatic rounds. Runs under Deno (`deno test`) and Node 23+ (`node --test playoffs.test.ts`).
import { test } from "node:test";
import assert from "node:assert/strict";
import cases from "../../../testdata/scheduled-events/cases.json" with { type: "json" };
import { mulberry32, pairRound, type ProposedMatch } from "./pairings.ts";
import { computeStandings } from "./standings.ts";
import {
  bracket, nextStage, nextStep, pairPlayoff, playoffStandings, seeds, swissRounds, type Stage, type StagedRound,
} from "./playoffs.ts";
import { placementRows } from "./placements.ts";
import type { Participant } from "./types.ts";

test("swiss rounds by players match the shared cases", () => {
  for (const c of cases.rounds) assert.equal(swissRounds(c.players), c.want, `${c.players} players`);
});

test("next step matches the shared cases", () => {
  for (const c of cases.next) {
    const got = nextStep({ stages: c.stages as Stage[], waiting: c.waiting, numberOfRounds: c.number_of_rounds,
                           topCut: c.top_cut, activePlayers: c.active_players, activeTeams: c.active_teams });
    assert.equal(got, c.want, JSON.stringify(c));
  }
  // Top 4 for players and for teams is in there, and the step that goes from Swiss straight to the semifinals.
  assert.ok(cases.next.some((c) => c.want === "cut4" && c.active_teams == null));
  assert.ok(cases.next.some((c) => c.want === "cut4" && c.active_teams != null));
});

const players = (n: number): Participant[] =>
  Array.from({ length: n }, (_, i) => ({
    id: `p${String(i + 1).padStart(2, "0")}`, eventId: "e", podId: "pod", displayName: `P${i + 1}`, seat: i + 1,
    status: "active", droppedInRound: null,
  }));

let ids = 0;
/** A played round: `winner(a, b)` says who wins each match 2–0 (or 2–1 when `close`). */
function play(stage: Stage, number: number, proposed: ProposedMatch[], winner: (a: string, b: string) => string,
              close = false): StagedRound {
  const roundId = `r${number}`;
  return {
    id: roundId, eventId: "e", number, status: "recorded", stage, timerDurationSeconds: 3000,
    timerRemainingAtChange: 3000, timerStatus: "running", timerLastStartedAt: null,
    matches: proposed.map((m) => {
      const id = `m${++ids}`;
      const w = m.isBye ? m.side0ParticipantId : winner(m.side0ParticipantId, m.side1ParticipantId!);
      return {
        id, eventId: "e", roundId, tableNumber: m.tableNumber, isBye: m.isBye, gameDraws: 0, intentionalDraw: false,
        status: "confirmed",
        sides: [
          { id: `${id}a`, matchId: id, participantId: m.side0ParticipantId, side: 0 as const,
            gameWins: m.isBye ? 2 : w === m.side0ParticipantId ? 2 : close ? 1 : 0 },
          ...(m.side1ParticipantId ? [{ id: `${id}b`, matchId: id, participantId: m.side1ParticipantId, side: 1 as const,
            gameWins: w === m.side1ParticipantId ? 2 : close ? 1 : 0 }] : []),
        ],
      };
    }),
  };
}

const lowerIdWins = (a: string, b: string) => (a < b ? a : b);

function swissEvent(n: number) {
  const ps = players(n);
  const rounds: StagedRound[] = [];
  const total = swissRounds(n);
  for (let r = 1; r <= total; r++) {
    rounds.push(play("swiss", r, pairRound({ participants: ps, rounds, roundNumber: r, rng: () => 0.5 }), lowerIdWins));
  }
  return { ps, rounds, total };
}

test("12 players: 4 Swiss rounds, then quarterfinals 1v8 4v5 2v7 3v6 with the higher seed on side 0", () => {
  const { ps, rounds, total } = swissEvent(12);
  assert.equal(total, 4);
  assert.equal(nextStage(rounds, total, 8, 12), "quarterfinal");
  assert.equal(nextStage(rounds, total, 0, 12), null);
  const top8 = computeStandings(ps, rounds).slice(0, 8).map((s) => s.participantId);
  const qf = pairPlayoff("quarterfinal", ps, rounds);
  assert.deepEqual(qf.map((m) => [m.tableNumber, m.side0ParticipantId, m.side1ParticipantId]), [
    [1, top8[0], top8[7]], [2, top8[3], top8[4]], [3, top8[1], top8[6]], [4, top8[2], top8[5]],
  ]);
});

test("a dropped player's place in the top 8 goes to the next one", () => {
  const { ps, rounds } = swissEvent(12);
  const order = computeStandings(ps, rounds).map((s) => s.participantId);
  const dropped = ps.map((p) => (p.id === order[2] ? { ...p, status: "dropped" as const, droppedInRound: 4 } : p));
  const seeded = [...seeds(dropped, rounds)].sort((a, b) => a[1] - b[1]).map(([id]) => id);
  assert.deepEqual(seeded, [order[0], order[1], order[3], order[4], order[5], order[6], order[7], order[8]]);
});

test("semifinals, final, final order and bracket; seeds stay put after a drop", () => {
  const { ps, rounds, total } = swissEvent(12);
  const seedOf = (id: string) => seeds(ps, rounds).get(id)!;
  // Seed 5 beats seed 4 in the quarterfinals; otherwise the higher seed wins.
  const upset = (a: string, b: string) => {
    const [x, y] = [seedOf(a), seedOf(b)];
    if ((x === 4 && y === 5) || (x === 5 && y === 4)) return x === 5 ? a : b;
    return x < y ? a : b;
  };
  const top = [...seeds(ps, rounds)].sort((a, b) => a[1] - b[1]).map(([id]) => id);
  rounds.push(play("quarterfinal", total + 1, pairPlayoff("quarterfinal", ps, rounds), upset, true));
  assert.equal(nextStage(rounds, total, 8, 12), "semifinal");
  // A quarterfinal loser drops: seeds are read from the quarterfinal tables, so nothing moves.
  const later = ps.map((p) => (p.id === top[7] ? { ...p, status: "dropped" as const, droppedInRound: 5 } : p));
  assert.deepEqual([...seeds(later, rounds)].sort((a, b) => a[1] - b[1]).map(([id]) => id), top);

  const sf = pairPlayoff("semifinal", later, rounds);
  assert.deepEqual(sf.map((m) => [m.side0ParticipantId, m.side1ParticipantId]), [[top[0], top[4]], [top[1], top[2]]]);
  rounds.push(play("semifinal", total + 2, sf, (a, b) => (seedOf(a) === 5 || seedOf(b) === 5 ? top[4] : upset(a, b))));
  const fin = pairPlayoff("final", later, rounds);
  assert.deepEqual(fin.map((m) => [m.side0ParticipantId, m.side1ParticipantId]), [[top[1], top[4]]]);
  rounds.push(play("final", total + 3, fin, () => top[4]));
  assert.equal(nextStage(rounds, total, 8, 12), null);

  const final = playoffStandings(later, rounds);
  assert.deepEqual(final.slice(0, 8).map((r) => [r.participantId, r.playoff]), [
    [top[4], "winner"], [top[1], "final"], [top[0], "semifinal"], [top[2], "semifinal"],
    [top[3], "quarterfinal"], [top[5], "quarterfinal"], [top[6], "quarterfinal"], [top[7], "quarterfinal"],
  ]);
  assert.deepEqual(final.map((r) => r.rank), final.map((_, i) => i + 1));
  const swiss = computeStandings(later, rounds.filter((r) => r.stage === "swiss"));
  assert.deepEqual(final.slice(8).map((r) => r.participantId), swiss.slice(8).map((s) => s.participantId));
  assert.ok(final.slice(8).every((r) => r.playoff === null));
  assert.equal(final[0].swissRank, 5);

  const b = bracket(later, rounds);
  assert.deepEqual(b.map((s) => [s.stage, s.matches.length]), [["quarterfinal", 4], ["semifinal", 2], ["final", 1]]);
  assert.deepEqual(b[0].matches[1].sides.map((s) => s.seed), [4, 5]);
  assert.equal(b[0].matches[1].winner, top[4]);
  assert.equal(b[2].matches[0].winner, top[4]);
});

test("the next stage waits for every playoff winner", () => {
  const { ps, rounds, total } = swissEvent(9);
  rounds.push(play("quarterfinal", total + 1, pairPlayoff("quarterfinal", ps, rounds), lowerIdWins));
  rounds[rounds.length - 1].matches[0].status = "pending";
  assert.throws(() => pairPlayoff("semifinal", ps, rounds), /needs a winner/);
});

test("no cut with 8 or fewer active players", () => {
  const { ps, rounds, total } = swissEvent(8);
  assert.equal(nextStage(rounds, total, 8, 8), null);
  assert.throws(() => pairPlayoff("quarterfinal", ps.slice(0, 7), rounds), /9 or more/);
  assert.deepEqual(bracket(ps, rounds), []);
  assert.deepEqual(playoffStandings(ps, rounds).map((r) => r.participantId),
                   computeStandings(ps, rounds).map((s) => s.participantId));
});

// ---------------------------------------------------------------------------------------------------------------
// Whole simulated events with a cut: random results, a drop along the way, every playoff round checked.

/** A Swiss event with random results (no draws); one player drops after round 1 when that still leaves a cut. */
function randomSwiss(n: number, seed: number, topCut: 4 | 8) {
  const rng = mulberry32(seed);
  let ps = players(n);
  const rounds: StagedRound[] = [];
  const total = swissRounds(n);
  for (let r = 1; r <= total; r++) {
    const pick = (a: string, b: string) => (rng() < 0.5 ? a : b);
    rounds.push(play("swiss", r, pairRound({ participants: ps, rounds, roundNumber: r, rng }), pick, rng() < 0.5));
    if (r === 1 && n > topCut + 1) {
      const gone = ps[Math.floor(rng() * n)].id;
      ps = ps.map((p) => (p.id === gone ? { ...p, status: "dropped" as const, droppedInRound: 1 } : p));
    }
  }
  return { ps, rounds, total, rng, active: ps.filter((p) => p.status === "active").length };
}

/** Plays the playoff stages in order with `rng` results; returns each stage's pairings and winners. */
function playCut(topCut: 4 | 8, ps: Participant[], rounds: StagedRound[], total: number, active: number, rng: () => number) {
  const stages: { stage: Stage; proposed: ProposedMatch[]; winners: string[] }[] = [];
  for (let next = nextStage(rounds, total, topCut, active); next; next = nextStage(rounds, total, topCut, active)) {
    assert.notEqual(next, "swiss");
    const proposed = pairPlayoff(next as Exclude<Stage, "swiss">, ps, rounds, topCut);
    const round = play(next, rounds.length + 1, proposed, (a, b) => (rng() < 0.5 ? a : b), true);
    rounds.push(round);
    stages.push({ stage: next, proposed, winners: round.matches.map((m) => (m.sides[0].gameWins > m.sides[1].gameWins ? m.sides[0] : m.sides[1]).participantId!) });
  }
  return stages;
}

test("top 4, 5 to 40 players: semifinals 1v4 and 2v3, the final, and places 1..n once each", () => {
  for (let n = 5; n <= 40; n++) {
    for (const seed of [1, 2, 3]) {
      const { ps, rounds, total, rng, active } = randomSwiss(n, n * 100 + seed, 4);
      const why = `${n} players, seed ${seed}`;
      const swiss = computeStandings(ps, rounds);
      const top = swiss.filter((s) => s.status === "active").slice(0, 4).map((s) => s.participantId);
      assert.deepEqual([...seeds(ps, rounds, 4)].sort((a, b) => a[1] - b[1]).map(([id]) => id), top, why);
      assert.equal(nextStage(rounds, total, 4, active), "semifinal", why);
      assert.equal(nextStep({ stages: rounds.map((r) => r.stage!), waiting: false, numberOfRounds: total, topCut: 4,
                              activePlayers: active }), "cut4", why);

      const stages = playCut(4, ps, rounds, total, active, rng);
      assert.deepEqual(stages.map((s) => s.stage), ["semifinal", "final"], why);
      const [sf, fin] = stages;
      // Table 1 is seed 1's match; the higher seed is side 0; every seed plays exactly once.
      assert.deepEqual(sf.proposed.map((m) => [m.tableNumber, m.side0ParticipantId, m.side1ParticipantId, m.isBye]),
                       [[1, top[0], top[3], false], [2, top[1], top[2], false]], why);
      const seedOf = seeds(ps, rounds);
      assert.deepEqual([...seedOf].sort((a, b) => a[1] - b[1]).map(([id]) => id), top, why);
      const finalists = [...sf.winners].sort((a, b) => seedOf.get(a)! - seedOf.get(b)!);
      assert.deepEqual(fin.proposed.map((m) => [m.tableNumber, m.side0ParticipantId, m.side1ParticipantId]),
                       [[1, finalists[0], finalists[1]]], why);
      assert.equal(nextStage(rounds, total, 4, active), null, why);

      const final = playoffStandings(ps, rounds);
      const champion = fin.winners[0];
      const losers = top.filter((id) => !sf.winners.includes(id));
      assert.deepEqual(final.slice(0, 4).map((r) => [r.participantId, r.playoff]), [
        [champion, "winner"], [finalists.find((id) => id !== champion), "final"],
        [losers[0], "semifinal"], [losers[1], "semifinal"],
      ], why);
      assert.deepEqual(final.map((r) => r.rank), final.map((_, i) => i + 1), why);
      assert.equal(new Set(final.map((r) => r.participantId)).size, n, why);
      // Everyone else keeps their Swiss order, and every number is still the Swiss one.
      assert.deepEqual(final.slice(4).map((r) => r.participantId),
                       swiss.filter((s) => !top.includes(s.participantId)).map((s) => s.participantId), why);
      assert.ok(final.slice(4).every((r) => r.playoff === null), why);
      for (const r of final) {
        const s = swiss.find((x) => x.participantId === r.participantId)!;
        assert.deepEqual([r.swissRank, r.matchPoints, r.opponentMatchWinPct], [s.rank, s.matchPoints, s.opponentMatchWinPct], why);
      }
      // A semifinalist dropping afterwards moves nothing: seeds are read from the semifinal tables.
      const later = ps.map((p) => (p.id === losers[0] ? { ...p, status: "dropped" as const, droppedInRound: total + 1 } : p));
      assert.deepEqual(playoffStandings(later, rounds).map((r) => r.participantId), final.map((r) => r.participantId), why);

      const b = bracket(ps, rounds);
      assert.deepEqual(b.map((s) => [s.stage, s.matches.length]), [["semifinal", 2], ["final", 1]], why);
      assert.deepEqual(b[0].matches.map((m) => m.sides.map((s) => s.seed)), [[1, 4], [2, 3]], why);
      assert.deepEqual(b[0].matches.map((m) => m.winner), sf.winners, why);
      assert.equal(b[1].matches[0].winner, champion, why);

      const places = placementRows(ps, rounds, [], false);
      assert.deepEqual(places.map((r) => r.place), final.map((_, i) => i + 1), why);
      assert.deepEqual(places.slice(0, 4).map((r) => r.playoff), ["winner", "final", "semifinal", "semifinal"], why);
    }
  }
});

test("top 8, 9 to 40 players: every seed once per round, the right seeds meet, places 1..n once each", () => {
  for (let n = 9; n <= 40; n++) {
    const { ps, rounds, total, rng, active } = randomSwiss(n, n * 100 + 7, 8);
    const why = `${n} players`;
    const swiss = computeStandings(ps, rounds);
    const top = swiss.filter((s) => s.status === "active").slice(0, 8).map((s) => s.participantId);
    assert.equal(nextStage(rounds, total, 8, active), "quarterfinal", why);
    const stages = playCut(8, ps, rounds, total, active, rng);
    assert.deepEqual(stages.map((s) => s.stage), ["quarterfinal", "semifinal", "final"], why);
    const [qf, sf, fin] = stages;
    assert.deepEqual(qf.proposed.map((m) => [m.tableNumber, m.side0ParticipantId, m.side1ParticipantId]), [
      [1, top[0], top[7]], [2, top[3], top[4]], [3, top[1], top[6]], [4, top[2], top[5]],
    ], why);
    const seedOf = seeds(ps, rounds);
    const bySeed = (a: string, b: string) => seedOf.get(a)! - seedOf.get(b)!;
    assert.deepEqual(sf.proposed.map((m) => [m.side0ParticipantId, m.side1ParticipantId]),
                     [qf.winners.slice(0, 2).sort(bySeed), qf.winners.slice(2).sort(bySeed)], why);
    assert.deepEqual(fin.proposed.map((m) => [m.side0ParticipantId, m.side1ParticipantId]), [[...sf.winners].sort(bySeed)], why);
    for (const s of stages) {
      const seated = s.proposed.flatMap((m) => [m.side0ParticipantId, m.side1ParticipantId]);
      assert.equal(new Set(seated).size, seated.length, why);
    }
    const final = playoffStandings(ps, rounds);
    assert.equal(final[0].participantId, fin.winners[0], why);
    assert.deepEqual(final.slice(0, 8).map((r) => r.playoff),
                     ["winner", "final", "semifinal", "semifinal", "quarterfinal", "quarterfinal", "quarterfinal", "quarterfinal"], why);
    assert.deepEqual(final.slice(4, 8).map((r) => r.participantId), top.filter((id) => !qf.winners.includes(id)), why);
    assert.deepEqual(final.map((r) => r.rank), final.map((_, i) => i + 1), why);
    assert.deepEqual(final.slice(8).map((r) => r.participantId),
                     swiss.filter((s) => !top.includes(s.participantId)).map((s) => s.participantId), why);
  }
});

test("top 4: no cut with 4 or fewer active players, and the stages it can't pair", () => {
  const { ps, rounds, total } = swissEvent(8);
  assert.equal(nextStage(rounds, total, 4, 4), null);
  assert.equal(nextStage(rounds, total, 4, 5), "semifinal");
  assert.equal(nextStage(rounds, total, 0, 8), null);
  assert.equal(nextStage(rounds, total, 8, 8), null);
  assert.throws(() => pairPlayoff("quarterfinal", ps, rounds, 4), /no quarterfinals/);
  assert.throws(() => pairPlayoff("semifinal", ps.slice(0, 3), rounds, 4), /5 or more/);
  assert.throws(() => pairPlayoff("final", ps, rounds, 4), /needs a winner/);
  // Without the cut size the semifinals still wait for quarterfinals, as a top 8 does.
  assert.throws(() => pairPlayoff("semifinal", ps, rounds), /needs a winner/);
  const sf = play("semifinal", total + 1, pairPlayoff("semifinal", ps, rounds, 4), lowerIdWins);
  sf.matches[1].status = "pending";
  assert.throws(() => pairPlayoff("final", ps, [...rounds, sf], 4), /needs a winner/);
  // A dropped player's place in the top 4 goes to the next one.
  const order = computeStandings(ps, rounds).map((s) => s.participantId);
  const dropped = ps.map((p) => (p.id === order[1] ? { ...p, status: "dropped" as const, droppedInRound: 3 } : p));
  assert.deepEqual([...seeds(dropped, rounds, 4)].sort((a, b) => a[1] - b[1]).map(([id]) => id),
                   [order[0], order[2], order[3], order[4]]);
});
