// Top 8 and automatic rounds. Runs under Deno (`deno test`) and Node 23+ (`node --test playoffs.test.ts`).
import { test } from "node:test";
import assert from "node:assert/strict";
import cases from "../../../testdata/scheduled-events/cases.json" with { type: "json" };
import { pairRound, type ProposedMatch } from "./pairings.ts";
import { computeStandings } from "./standings.ts";
import {
  bracket, nextStage, nextStep, pairPlayoff, playoffStandings, seeds, swissRounds, type Stage, type StagedRound,
} from "./playoffs.ts";
import type { Participant } from "./types.ts";

test("swiss rounds by players match the shared cases", () => {
  for (const c of cases.rounds) assert.equal(swissRounds(c.players), c.want, `${c.players} players`);
});

test("next step matches the shared cases", () => {
  for (const c of cases.next) {
    const got = nextStep({ stages: c.stages as Stage[], waiting: c.waiting, numberOfRounds: c.number_of_rounds,
                           topCut: c.top_cut, activePlayers: c.active_players });
    assert.equal(got, c.want, JSON.stringify(c));
  }
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
