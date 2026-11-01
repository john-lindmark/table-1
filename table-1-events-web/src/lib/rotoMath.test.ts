import { describe, expect, it } from "vitest";
import {
  addClockRange, clockSeconds, countdownText, defaultPairing, durationText, manaValue, mergePicks, pickNoAt, picksUntil,
  rotoCard, roundOf, roundRobinRoundsFor, seatFor, toState, type RotoPick,
} from "./rotoMath";

// Same cases as apps/ios/Table1Tests/RotoTests.swift.

describe("turn maths", () => {
  it("snake order for 8, 7 and 2 players; same order", () => {
    expect(Array.from({ length: 16 }, (_, i) => seatFor(8, i + 1, true))).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 8, 7, 6, 5, 4, 3, 2, 1]);
    expect(seatFor(8, 17, true)).toBe(1);
    expect(Array.from({ length: 14 }, (_, i) => seatFor(7, i + 1, true))).toEqual([1, 2, 3, 4, 5, 6, 7, 7, 6, 5, 4, 3, 2, 1]);
    expect(Array.from({ length: 6 }, (_, i) => seatFor(2, i + 1, true))).toEqual([1, 2, 2, 1, 1, 2]);
    expect(Array.from({ length: 6 }, (_, i) => seatFor(3, i + 1, false))).toEqual([1, 2, 3, 1, 2, 3]);
  });

  it("the last pick of 45 rounds", () => {
    expect(roundOf(8, 360)).toBe(45);
    expect(seatFor(8, 353, true)).toBe(1);
    expect(seatFor(8, 360, true)).toBe(8);
  });

  it("pickNoAt is the inverse of seat and round", () => {
    for (const snake of [true, false]) {
      for (let n = 1; n <= 360; n++) expect(pickNoAt(seatFor(8, n, snake), roundOf(8, n), 8, snake)).toBe(n);
    }
  });

  it("picks until mine", () => {
    expect(picksUntil(3, 0, 8, 360, true)).toBe(2);
    expect(picksUntil(3, 2, 8, 360, true)).toBe(0);
    // Seat 3 just picked (pick 3); its next is pick 14 (round 2 runs 8 → 1).
    expect(picksUntil(3, 3, 8, 360, true)).toBe(10);
    // The turn: seat 8 picks 8 and 9.
    expect(picksUntil(8, 8, 8, 360, true)).toBe(0);
    expect(picksUntil(1, 360, 8, 360, true)).toBeNull();
  });

  it("the clock schedule quickens", () => {
    const clock = [{ fromRound: 1, seconds: 14400 }, { fromRound: 11, seconds: 7200 }, { fromRound: 31, seconds: 1800 }];
    expect(clockSeconds(clock, 1)).toBe(14400);
    expect(clockSeconds(clock, 10)).toBe(14400);
    expect(clockSeconds(clock, 11)).toBe(7200);
    expect(clockSeconds(clock, 45)).toBe(1800);
    expect(clockSeconds(null, 3)).toBeNull();
    expect(countdownText(6130)).toBe("1:42:10");
    expect(countdownText(245)).toBe("4:05");
    expect(durationText(5400)).toBe("1 h 30 min");
    expect(durationText(14400)).toBe("4 h");
    expect(durationText(30)).toBe("30 s");
  });

  it("Add a range splits the last one at about half the time", () => {
    expect(addClockRange([], 45)).toEqual([{ fromRound: 1, seconds: 14400 }]);
    expect(addClockRange([{ fromRound: 1, seconds: 14400 }], 45)).toEqual([
      { fromRound: 1, seconds: 14400 },
      { fromRound: 23, seconds: 7200 },
    ]);
  });

  it("pairing defaults", () => {
    expect(defaultPairing(2)).toBe("round_robin");
    expect(defaultPairing(8)).toBe("round_robin");
    expect(defaultPairing(9)).toBe("swiss");
    expect(roundRobinRoundsFor(8)).toBe(7);
    expect(roundRobinRoundsFor(7)).toBe(7);
    expect(roundRobinRoundsFor(0)).toBe(1);
  });
});

describe("merging deltas", () => {
  const picks = (from: number, to: number, slotOffset = 100): RotoPick[] =>
    Array.from({ length: to - from + 1 }, (_, i) => {
      const n = from + i;
      return { pickNo: n, seat: seatFor(8, n, true), slot: n + slotOffset, how: "player", at: 0 };
    });

  it("a delta appends", () => {
    const r = mergePicks(picks(1, 35), picks(36, 40), 40);
    expect(r.picks.map((p) => p.pickNo)).toEqual(Array.from({ length: 40 }, (_, i) => i + 1));
    expect(r.needsFull).toBe(false);
  });

  it("an empty delta keeps everything", () => {
    const r = mergePicks(picks(1, 35), [], 35);
    expect(r.picks).toHaveLength(35);
    expect(r.needsFull).toBe(false);
  });

  it("an undo drops picks above and asks for a full fetch", () => {
    const r = mergePicks(picks(1, 35), [], 30);
    expect(r.picks.map((p) => p.pickNo)).toEqual(Array.from({ length: 30 }, (_, i) => i + 1));
    expect(r.needsFull).toBe(true);
  });

  it("a rewritten pick shows as a duplicate slot", () => {
    const delta = picks(36, 37);
    delta[0] = { ...delta[0], slot: 132 };
    expect(mergePicks(picks(1, 35), delta, 37).needsFull).toBe(true);
  });

  it("a gap asks for a full fetch", () => {
    expect(mergePicks(picks(1, 10), picks(13, 14), 14).needsFull).toBe(true);
  });

  it("a full fetch replaces", () => {
    const fresh = picks(1, 33, 500);
    const r = mergePicks([], fresh, 33);
    expect(r.picks).toEqual(fresh);
    expect(r.needsFull).toBe(false);
  });
});

describe("wire", () => {
  it("reads roto_state", () => {
    const s = toState({
      event_id: "e1", phase: "drafting",
      draft: { picks_per_player: 45, pick_order: "snake", players: 8, pool_count: 360, picks_made: 2, total_picks: 360,
               source_list_id: null, clock: [{ from_round: 1, seconds: 14400 }], clock_paused: false, started_at: 1760000000,
               finished_at: null },
      on_clock: { participant_id: "p3", seat: 3, pick_no: 3, round: 1, turn_started_at: 1760000100, turn_seconds: 14400,
                  remaining_seconds: null, deadline: 1760014500, overdue: false },
      seats: [{ seat: 1, participant_id: "p1", display_name: "Ann", account: true, me: false },
              { seat: 3, participant_id: "p3", display_name: "Cy", account: false, me: true }],
      picks: [[1, 1, 17, "player", 1760000050], [2, 2, 4, "auto", 1760000100]],
      pool: [[1, "c-1", "nonfoil"], [2, "c-2", "foil"]],
      me: { participant_id: "p3", seat: 3, queue: [5, 9], auto_pick: true, deck_list_id: "d1" },
    });
    expect(s.phase).toBe("drafting");
    expect(s.draft.picksMade).toBe(2);
    expect(s.draft.clock?.[0].seconds).toBe(14400);
    expect(s.onClock?.seat).toBe(3);
    expect(s.picks.map((p) => p.slot)).toEqual([17, 4]);
    expect(s.picks[1].how).toBe("auto");
    expect(s.pool?.[1].finish).toBe("foil");
    expect(s.me?.queue).toEqual([5, 9]);
    expect(s.me?.deckListId).toBe("d1");
  });

  it("a delta answer has no pool and setup has no clock", () => {
    const s = toState({ event_id: "e1", phase: "setup", draft: {}, on_clock: null, seats: [], picks: [], pool: null, me: null });
    expect(s.pool).toBeNull();
    expect(s.onClock).toBeNull();
    expect(s.draft.picksPerPlayer).toBe(45);
  });
});

describe("cards", () => {
  it("mana value and color groups", () => {
    expect(manaValue("{2}{U}{U}")).toBe(4);
    expect(manaValue("{X}{R}")).toBe(1);
    expect(manaValue("{W/P}{G/U}")).toBe(2);
    expect(manaValue("{1}{R} // {3}{U}")).toBe(2);
    expect(rotoCard("a", "Bolt", "Instant", "{R}", null).group).toBe("Red");
    expect(rotoCard("a", "Fire // Ice", "Instant // Instant", "{1}{R} // {1}{U}", null).group).toBe("Multicolor");
    expect(rotoCard("a", "Sol Ring", "Artifact", "{1}", null).group).toBe("Colorless");
    expect(rotoCard("a", "Tundra", "Land — Plains Island", "", null).group).toBe("Lands");
    expect(rotoCard("a", "Kitesail", "Creature — Human", "{W/P}", null).colors).toEqual(["W"]);
  });
});
