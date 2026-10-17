// Round robin schedule checks: a copy of supabase/functions/events-engine/roundrobin.test.ts for Vitest.
import { expect, test } from "vitest";
import { pairRoundRobin, roundRobinPairs, roundRobinRounds } from "./roundrobin";
import type { Participant } from "./types";

const players = (n: number): Participant[] =>
  Array.from({ length: n }, (_, i) => ({
    id: `p${i + 1}`, eventId: "e", podId: "pod", displayName: `P${i + 1}`, seat: i + 1,
    status: "active", droppedInRound: null,
  }));

const assert = {
  equal: (a: unknown, b: unknown, msg?: string) => expect(a, msg).toBe(b),
  deepEqual: (a: unknown, b: unknown) => expect(a).toEqual(b),
  ok: (v: unknown, msg?: string) => expect(v, msg).toBeTruthy(),
};

const key = (a: string, b: string) => (a < b ? `${a}|${b}` : `${b}|${a}`);

test("every pair meets exactly once, one bye a round when odd, nobody gets two byes (n = 2..12)", () => {
  for (let n = 2; n <= 12; n++) {
    const ps = players(n);
    const rounds = roundRobinRounds(n);
    assert.equal(rounds, n % 2 === 0 ? n - 1 : n);
    const met = new Map<string, number>();
    const byes = new Map<string, number>();
    for (let r = 1; r <= rounds; r++) {
      const ms = pairRoundRobin(ps, r);
      const seen = new Set<string>();
      for (const m of ms) {
        for (const id of [m.side0ParticipantId, m.side1ParticipantId]) {
          if (!id) continue;
          assert.ok(!seen.has(id), `n=${n} r=${r}: ${id} twice`);
          seen.add(id);
        }
        if (m.isBye) byes.set(m.side0ParticipantId, (byes.get(m.side0ParticipantId) ?? 0) + 1);
        else met.set(key(m.side0ParticipantId, m.side1ParticipantId!), (met.get(key(m.side0ParticipantId, m.side1ParticipantId!)) ?? 0) + 1);
      }
      assert.equal(seen.size, n, `n=${n} r=${r}: everyone plays or has the bye`);
      assert.equal(ms.filter((m) => m.isBye).length, n % 2);
    }
    assert.equal(met.size, (n * (n - 1)) / 2, `n=${n}: every pair`);
    assert.ok([...met.values()].every((v) => v === 1), `n=${n}: no rematch`);
    assert.ok([...byes.values()].every((v) => v === 1), `n=${n}: one bye each at most`);
    if (n % 2 === 1) assert.equal(byes.size, n);
  }
});

test("the schedule is stable and table numbers put byes last", () => {
  const ps = players(7);
  assert.deepEqual(pairRoundRobin(ps, 3), pairRoundRobin(ps, 3));
  const ms = pairRoundRobin(ps, 2);
  assert.deepEqual(ms.map((m) => m.tableNumber), [1, 2, 3, 4]);
  assert.equal(ms.at(-1)!.isBye, true);
});

test("matches t1_private.demo_round's rotation", () => {
  // demo_round: rot = [ids[1]] + ids[2 + ((g + r - 1) % (n - 1))], pairs rot[k+1] vs rot[n-k] (1-based).
  const ids = ["a", "b", "c", "d", "e", "f", "g", "h"];
  assert.deepEqual(roundRobinPairs(ids, 1), [["a", "h"], ["b", "g"], ["c", "f"], ["d", "e"]]);
  assert.deepEqual(roundRobinPairs(ids, 2), [["a", "b"], ["c", "h"], ["d", "g"], ["e", "f"]]);
});

test("a player who drops later gives each remaining opponent a bye", () => {
  const ps = players(6);
  ps[2] = { ...ps[2], status: "dropped", droppedInRound: 2 };
  for (let r = 3; r <= 5; r++) {
    const ms = pairRoundRobin(ps, r);
    assert.ok(ms.every((m) => m.side0ParticipantId !== "p3" && m.side1ParticipantId !== "p3"));
    assert.equal(ms.filter((m) => m.isBye).length, 1);
    assert.equal(ms.filter((m) => !m.isBye).length, 2);
  }
});

test("a player who dropped before round 1 isn't in the schedule", () => {
  const ps = players(5);
  ps[4] = { ...ps[4], status: "dropped", droppedInRound: 0 };
  assert.equal(pairRoundRobin(ps, 1).filter((m) => !m.isBye).length, 2);
  assert.equal(pairRoundRobin(ps, 1).length, 2);
});
