// Drafts with several pods (contract/draft-pods-2026-11-09.md): pod plans, automatic rounds, round 1 across every
// pod, and whole simulated events paired inside pods or across them, with drops, checked round by round.
// Runs under Deno (`deno test`) and Node 23+ (`node --test pods.test.ts`).
import { test } from "node:test";
import assert from "node:assert/strict";
import cases from "../../../testdata/draft-pods/cases.json" with { type: "json" };
import { mulberry32, pairRound, previousOpponents, type ProposedMatch } from "./pairings.ts";
import { podCount, podLabel, podPlan, roundOnePlan, seatDraft } from "./seating.ts";
import { draftRounds } from "./playoffs.ts";
import { computeStandings } from "./standings.ts";
import type { Participant, RoundWithMatches } from "./types.ts";

test("pod plans match the shared cases", () => {
  for (const c of cases.plan) {
    assert.deepEqual(podPlan(c.players, c.pods), c.want, JSON.stringify(c));
    assert.equal(podCount(c.players, c.pods), c.want.length, JSON.stringify(c));
  }
});

test("automatic rounds follow the pods (shared cases)", () => {
  for (const c of cases.rounds) {
    assert.equal(draftRounds(c.sizes, c.pod_pairing as "pod" | "cross"), c.want, JSON.stringify(c));
  }
});

test("pick labels match the shared cases", () => {
  for (const c of cases.label) assert.equal(podLabel(c.players, c.pods), c.want, JSON.stringify(c));
});

test("round 1 plans match the shared cases", () => {
  for (const c of cases.round1) {
    const pods = c.sizes.map((n, p) =>
      Array.from({ length: n }, (_, s) => ({ participantId: `P${p + 1}S${s + 1}`, podId: `pod${p + 1}`, seat: s + 1 })));
    assert.deepEqual(roundOnePlan(pods), c.want, JSON.stringify(c.sizes));
  }
});

// ---------------------------------------------------------------------------------------------------------------
// A seated draft: seatDraft's pods become pod ids pod0, pod1, …
function seated(n: number, pods: number | null, seed: number): Participant[] {
  const ids = Array.from({ length: n }, (_, i) => `p${String(i + 1).padStart(3, "0")}`);
  return seatDraft(ids, mulberry32(seed), pods).map((s) => ({
    id: s.participantId, eventId: "e", podId: `pod${s.podIndex}`, displayName: s.participantId, seat: s.seat,
    status: "active", droppedInRound: null,
  }));
}

let matchIds = 0;
function play(number: number, proposed: ProposedMatch[], rng: () => number): RoundWithMatches {
  return {
    id: `r${number}`, eventId: "e", number, status: "recorded", timerDurationSeconds: 3000,
    timerRemainingAtChange: 3000, timerStatus: "running", timerLastStartedAt: null,
    matches: proposed.map((m) => {
      const id = `m${++matchIds}`;
      const roll = rng();
      const [a, b, d] = m.isBye ? [2, 0, 0] : roll < 0.45 ? [2, roll < 0.2 ? 0 : 1, 0] : roll < 0.9 ? [roll < 0.7 ? 0 : 1, 2, 0] : [1, 1, 1];
      return {
        id, eventId: "e", roundId: `r${number}`, tableNumber: m.tableNumber, isBye: m.isBye, gameDraws: d,
        intentionalDraw: false, status: "confirmed",
        sides: [
          { id: `${id}a`, matchId: id, participantId: m.side0ParticipantId, side: 0 as const, gameWins: a },
          ...(m.side1ParticipantId ? [{ id: `${id}b`, matchId: id, participantId: m.side1ParticipantId, side: 1 as const, gameWins: b }] : []),
        ],
      };
    }),
  };
}

const key = (a: string, b: string) => (a < b ? `${a}|${b}` : `${b}|${a}`);

interface Sim {
  players: number; pods: number | null; pairing: "pod" | "cross"; seed: number;
  /** Drop this many random players after each of these rounds. */
  drops?: Record<number, number>;
}

/** Plays a whole event and checks every round. Returns counts the callers assert on. */
function simulate(sim: Sim) {
  const rng = mulberry32(sim.seed * 7919 + 1);
  let people = seated(sim.players, sim.pods, sim.seed);
  const podOrder = [...new Set(people.map((p) => p.podId!))].sort((a, b) => Number(a.slice(3)) - Number(b.slice(3)));
  const sizes = podPlan(sim.players, sim.pods);
  const total = draftRounds(sizes, sim.pairing);
  const rounds: RoundWithMatches[] = [];
  let rematches = 0, secondByes = 0, crossPod = 0, spills = 0;
  const byes = new Map<string, number>();
  for (let r = 1; r <= total; r++) {
    const proposed = pairRound({ participants: people, rounds, roundNumber: r, draftSeating: true, podOrder,
                                 podPairing: sim.pairing, rng });
    const active = people.filter((p) => p.status === "active");
    const podOf = new Map(people.map((p) => [p.id, p.podId!]));
    const where = `${JSON.stringify(sim)} round ${r}`;

    // Everyone active plays exactly once; nobody else does.
    const seen = proposed.flatMap((m) => [m.side0ParticipantId, m.side1ParticipantId].filter(Boolean) as string[]);
    assert.equal(seen.length, new Set(seen).size, `${where}: someone paired twice`);
    assert.deepEqual([...seen].sort(), active.map((p) => p.id).sort(), `${where}: not everyone paired`);
    // Tables 1..k, the bye last and only for an odd event.
    assert.deepEqual(proposed.map((m) => m.tableNumber), proposed.map((_, i) => i + 1), `${where}: tables`);
    const byeMatches = proposed.filter((m) => m.isBye);
    assert.equal(byeMatches.length, active.length % 2, `${where}: byes`);
    if (byeMatches.length) assert.ok(proposed.at(-1)!.isBye, `${where}: bye not last`);

    const played = previousOpponents(rounds);
    const games = proposed.filter((m) => !m.isBye);
    for (const m of games) if (played.has(key(m.side0ParticipantId, m.side1ParticipantId!))) rematches++;
    for (const m of byeMatches) {
      const n = (byes.get(m.side0ParticipantId) ?? 0) + 1;
      byes.set(m.side0ParticipantId, n);
      if (n > 1) secondByes++;
    }

    // Inside pods (and every round 1): only the seats odd pods leave over cross, at most one per pod, and they
    // come after every in-pod table. Each pod's in-pod tables come in pod order.
    if (sim.pairing === "pod" || r === 1) {
      const counts = new Map<string, number>();
      for (const p of active) counts.set(p.podId!, (counts.get(p.podId!) ?? 0) + 1);
      const oddPods = [...counts.values()].filter((n) => n % 2 === 1).length;
      const across = games.filter((m) => podOf.get(m.side0ParticipantId) !== podOf.get(m.side1ParticipantId!));
      const crossers = across.flatMap((m) => [m.side0ParticipantId, m.side1ParticipantId!])
        .concat(byeMatches.map((m) => m.side0ParticipantId));
      const perPod = new Map<string, number>();
      for (const id of crossers) perPod.set(podOf.get(id)!, (perPod.get(podOf.get(id)!) ?? 0) + 1);
      for (const [pod, size] of counts) {
        const n = perPod.get(pod) ?? 0, parity = size % 2;
        if (n === parity) continue;
        // Two more over only from a pod too small to pair without a rematch, and never in round 1.
        assert.ok(r > 1 && n === parity + 2 && size <= total + 1, `${where}: ${pod} (${size}) left over ${n}`);
        spills++;
      }
      if (r === 1) assert.equal(across.length, Math.floor(oddPods / 2), `${where}: across-pod matches`);
      const firstAcross = proposed.findIndex((m) => !m.isBye && across.includes(m));
      const inPod = games.filter((m) => !across.includes(m));
      if (firstAcross >= 0) assert.ok(proposed.slice(0, firstAcross).every((m) => inPod.includes(m)), `${where}: across-pod table before an in-pod one`);
      const order = inPod.map((m) => podOrder.indexOf(podOf.get(m.side0ParticipantId)!));
      assert.deepEqual(order, [...order].sort((a, b) => a - b), `${where}: in-pod tables out of pod order`);
      crossPod += across.length;
    } else {
      crossPod += games.filter((m) => podOf.get(m.side0ParticipantId) !== podOf.get(m.side1ParticipantId!)).length;
    }

    // Round 1 is across each table.
    if (r === 1) {
      for (const m of games) {
        const a = people.find((p) => p.id === m.side0ParticipantId)!, b = people.find((p) => p.id === m.side1ParticipantId)!;
        if (a.podId !== b.podId) continue;
        const size = active.filter((p) => p.podId === a.podId).length;
        assert.equal(b.seat! - a.seat!, Math.floor(size / 2), `${where}: ${a.id} v ${b.id} not across`);
      }
    }

    rounds.push(play(r, proposed, rng));
    const drop = sim.drops?.[r] ?? 0;
    for (let i = 0; i < drop; i++) {
      const left = people.filter((p) => p.status === "active");
      if (left.length <= 2) break;
      const out = left[Math.floor(rng() * left.length)];
      people = people.map((p) => p.id === out.id ? { ...p, status: "dropped", droppedInRound: r } : p);
    }
  }
  return { rounds, people, rematches, secondByes, crossPod, total, spills };
}

test("simulated drafts inside pods: no rematches, no second byes, only left-over seats cross", () => {
  let events = 0, spills = 0;
  for (const players of [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 21, 23, 24, 25, 30, 31, 32, 33, 40, 47, 48, 64]) {
    for (const pods of [null, 1, 2, 3, 4, 5]) {
      for (let seed = 1; seed <= 6; seed++) {
        const r = simulate({ players, pods, pairing: "pod", seed });
        assert.equal(r.rematches, 0, `rematch: ${players} players, pods ${pods}, seed ${seed}`);
        assert.equal(r.secondByes, 0, `second bye: ${players} players, pods ${pods}, seed ${seed}`);
        events++;
        spills += r.spills;
      }
    }
  }
  assert.ok(events > 900);
  console.log(`pods: ${events} simulated events, ${spills} rounds where a small pod sent two more across`);
});

test("simulated drafts across pods: round 1 in pods, then Swiss with everyone, no rematches", () => {
  let mixed = 0;
  for (const players of [9, 12, 14, 16, 17, 20, 24, 25, 32, 33, 48]) {
    for (const pods of [null, 2, 3, 4]) {
      for (let seed = 1; seed <= 6; seed++) {
        const r = simulate({ players, pods, pairing: "cross", seed });
        assert.equal(r.rematches, 0, `rematch: ${players} players, pods ${pods}, seed ${seed}`);
        assert.equal(r.secondByes, 0, `second bye: ${players} players, pods ${pods}, seed ${seed}`);
        // Swiss across pods meets people from other pods after round 1.
        if (podPlan(players, pods).length > 1) mixed += r.crossPod;
      }
    }
  }
  assert.ok(mixed > 200, `only ${mixed} across-pod matches`);
});

test("simulated drafts with drops still pair everyone every round, inside and across pods", () => {
  for (const pairing of ["pod", "cross"] as const) {
    for (const players of [8, 11, 16, 17, 24, 31]) {
      for (const pods of [null, 2, 3]) {
        for (let seed = 1; seed <= 8; seed++) {
          // The checks inside simulate (everyone once, byes only when odd, left-over seats) are what's tested.
          const r = simulate({ players, pods, pairing, seed, drops: { 1: 1, 2: 2 } });
          assert.ok(r.people.some((p) => p.status === "dropped"));
        }
      }
    }
  }
});

test("a pod emptied down to one player: that player plays across pods every round", () => {
  let people = seated(10, 2, 3);  // 5 + 5
  const podOrder = ["pod0", "pod1"];
  const rng = mulberry32(5);
  const rounds: RoundWithMatches[] = [];
  rounds.push(play(1, pairRound({ participants: people, rounds, roundNumber: 1, draftSeating: true, podOrder, podPairing: "pod" }), rng));
  const pod1 = people.filter((p) => p.podId === "pod1").map((p) => p.id);
  people = people.map((p) => pod1.slice(0, 4).includes(p.id) ? { ...p, status: "dropped", droppedInRound: 1 } : p);
  const last = pod1[4];
  const m = pairRound({ participants: people, rounds, roundNumber: 2, draftSeating: true, podOrder, podPairing: "pod" });
  const theirs = m.find((x) => x.side0ParticipantId === last || x.side1ParticipantId === last)!;
  assert.equal(theirs.isBye, false, "5 + 1 active: the lone player plays the left-over from pod 0");
  assert.equal(m.filter((x) => x.isBye).length, 0);
});

test("inside pods, standings decide the pairs: pod leaders meet pod leaders", () => {
  const people = seated(16, 2, 9);
  const podOrder = ["pod0", "pod1"];
  const rounds: RoundWithMatches[] = [];
  const r1 = pairRound({ participants: people, rounds, roundNumber: 1, draftSeating: true, podOrder, podPairing: "pod" });
  // Side 0 wins every match in round 1.
  rounds.push(play(1, r1, () => 0.1));
  const r2 = pairRound({ participants: people, rounds, roundNumber: 2, draftSeating: true, podOrder, podPairing: "pod" });
  const winners = new Set(r1.map((m) => m.side0ParticipantId));
  for (const m of r2) {
    assert.equal(winners.has(m.side0ParticipantId), winners.has(m.side1ParticipantId!), "1-0 v 1-0 and 0-1 v 0-1 inside each pod");
  }
  const podOf = new Map(people.map((p) => [p.id, p.podId]));
  assert.ok(r2.every((m) => podOf.get(m.side0ParticipantId) === podOf.get(m.side1ParticipantId!)));
  assert.deepEqual(r2.map((m) => podOf.get(m.side0ParticipantId)), ["pod0", "pod0", "pod0", "pod0", "pod1", "pod1", "pod1", "pod1"]);
});

test("odd pods: the left-over player is from the bottom of the pod and the bye goes to someone without one", () => {
  const people = seated(21, 3, 4);  // 7 + 7 + 7
  const podOrder = ["pod0", "pod1", "pod2"];
  const rounds: RoundWithMatches[] = [];
  const rng = mulberry32(11);
  for (let r = 1; r <= 3; r++) {
    const m = pairRound({ participants: people, rounds, roundNumber: r, draftSeating: true, podOrder, podPairing: "pod" });
    if (r > 1) {
      const standings = computeStandings(people, rounds);
      const place = new Map(standings.map((s, i) => [s.participantId, i]));
      const podOf = new Map(people.map((p) => [p.id, p.podId]));
      const crossers = m.filter((x) => x.isBye || podOf.get(x.side0ParticipantId) !== podOf.get(x.side1ParticipantId!))
        .flatMap((x) => [x.side0ParticipantId, x.side1ParticipantId].filter(Boolean) as string[]);
      for (const id of crossers) {
        const pod = people.filter((p) => p.podId === podOf.get(id)).map((p) => place.get(p.id)!).sort((a, b) => a - b);
        // Lowest-ranked of the pod, or one of the bottom three (when the bottom player would rematch).
        assert.ok(pod.indexOf(place.get(id)!) >= pod.length - 3, `round ${r}: ${id} isn't near the bottom of their pod`);
      }
    }
    rounds.push(play(r, m, rng));
  }
});

test("pairing inside pods stays fast: 16 pods of 8, 16 pods of 7", () => {
  for (const [n, pods] of [[128, 16], [112, 16], [129, null]] as [number, number | null][]) {
    const people = seated(n, pods, 2);
    const podOrder = [...new Set(people.map((p) => p.podId!))].sort((a, b) => Number(a.slice(3)) - Number(b.slice(3)));
    const rounds: RoundWithMatches[] = [];
    const rng = mulberry32(3);
    let worst = 0;
    for (let r = 1; r <= 3; r++) {
      const t0 = performance.now();
      const m = pairRound({ participants: people, rounds, roundNumber: r, draftSeating: true, podOrder, podPairing: "pod" });
      worst = Math.max(worst, performance.now() - t0);
      rounds.push(play(r, m, rng));
    }
    console.log(`perf swiss pods ${n} players / ${podOrder.length} pods: worst round ${worst.toFixed(1)} ms`);
    assert.ok(worst < 250, `${n} players: ${worst} ms`);
  }
});

test("older events (no pod pairing given) keep pairing across pods after round 1", () => {
  const people = seated(16, 2, 1);
  const podOrder = ["pod0", "pod1"];
  const rounds: RoundWithMatches[] = [];
  rounds.push(play(1, pairRound({ participants: people, rounds, roundNumber: 1, draftSeating: true, podOrder }), mulberry32(1)));
  const a = pairRound({ participants: people, rounds, roundNumber: 2, draftSeating: true, podOrder, rng: mulberry32(2) });
  const b = pairRound({ participants: people, rounds, roundNumber: 2, draftSeating: true, podOrder, podPairing: "cross", rng: mulberry32(2) });
  assert.deepEqual(a, b);
});
