// Final places kept for leagues. Runs under Deno (`deno test`) and Node 23+.
import { test } from "node:test";
import assert from "node:assert/strict";
import { pairRound, type ProposedMatch } from "./pairings.ts";
import { pairPlayoff, swissRounds, type Stage, type StagedRound } from "./playoffs.ts";
import { placementRows } from "./placements.ts";
import type { Participant } from "./types.ts";

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
        status: "confirmed",
        sides: [
          { id: `${id}a`, matchId: id, participantId: m.side0ParticipantId, side: 0 as const,
            gameWins: m.isBye || w === m.side0ParticipantId ? 2 : 0 },
          ...(m.side1ParticipantId ? [{ id: `${id}b`, matchId: id, participantId: m.side1ParticipantId, side: 1 as const,
            gameWins: w === m.side1ParticipantId ? 2 : 0 }] : []),
        ],
      };
    }),
  };
}
const lowerIdWins = (a: string, b: string) => (a < b ? a : b);
const higherIdWins = (a: string, b: string) => (a > b ? a : b);

test("an individual event: places 1..n once each, the Swiss leader first with no cut", () => {
  const ps = players(9);
  const rounds: StagedRound[] = [];
  for (let r = 1; r <= swissRounds(9); r++) {
    rounds.push(play("swiss", r, pairRound({ participants: ps, rounds, roundNumber: r, rng: () => 0.5 }), lowerIdWins));
  }
  const rows = placementRows(ps, rounds, [], false);
  assert.deepEqual(rows.map((r) => r.place), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  assert.equal(rows[0].participant_id, "p01");
  assert.equal(rows[0].match_points, rows[0].match_wins * 3 + rows[0].match_draws);
  assert.ok(rows.every((r) => r.playoff === null && r.team_id === null));
});

test("with a top 8 the final's winner is first, whatever their Swiss standing", () => {
  const ps = players(12);
  const rounds: StagedRound[] = [];
  const total = swissRounds(12);
  for (let r = 1; r <= total; r++) {
    rounds.push(play("swiss", r, pairRound({ participants: ps, rounds, roundNumber: r, rng: () => 0.5 }), lowerIdWins));
  }
  // The lower seed wins every playoff match, so the 8th seed takes it.
  const swissOrder = placementRows(ps, rounds, [], false).map((r) => r.participant_id);
  const seedOf = new Map(swissOrder.map((id, i) => [id, i + 1]));
  const upset = (a: string, b: string) => (seedOf.get(a)! > seedOf.get(b)! ? a : b);
  let n = total;
  for (const stage of ["quarterfinal", "semifinal", "final"] as const) {
    rounds.push(play(stage, ++n, pairPlayoff(stage, ps, rounds), upset));
  }
  const rows = placementRows(ps, rounds, [], false);
  assert.equal(rows[0].participant_id, swissOrder[7]);
  assert.equal(rows[0].playoff, "winner");
  assert.equal(rows[1].playoff, "final");
  assert.deepEqual(rows.slice(2, 4).map((r) => r.playoff), ["semifinal", "semifinal"]);
  assert.deepEqual(rows.map((r) => r.place), Array.from({ length: 12 }, (_, i) => i + 1));
  assert.equal(new Set(rows.slice(0, 8).map((r) => r.participant_id)).size, 8);
});

test("a team event: every member takes the team's place; a player on no team sits behind the teams", () => {
  const ps = players(7).map((p, i) => ({ ...p, teamId: i < 3 ? "tA" : i < 6 ? "tB" : null, teamSlot: i < 6 ? (i % 3) + 1 : null }));
  const teams = [{ id: "tA", name: "A", order: 0 }, { id: "tB", name: "B", order: 1 }];
  const proposed: ProposedMatch[] = [0, 1, 2].map((s) => ({
    tableNumber: s + 1, isBye: false, side0ParticipantId: ps[s].id, side1ParticipantId: ps[s + 3].id, podId: "pod",
  } as ProposedMatch));
  const rows = placementRows(ps, [play("swiss", 1, proposed, higherIdWins)], teams, true);
  const place = new Map(rows.map((r) => [r.participant_id, r.place]));
  assert.deepEqual(["p04", "p05", "p06"].map((id) => place.get(id)), [1, 1, 1]);
  assert.deepEqual(["p01", "p02", "p03"].map((id) => place.get(id)), [2, 2, 2]);
  assert.equal(place.get("p07"), 3);
  assert.equal(rows.find((r) => r.participant_id === "p04")!.team_id, "tB");
});
