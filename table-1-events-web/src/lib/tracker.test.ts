import { describe, expect, it } from "vitest";
import {
  canRecord,
  clampDelta,
  clockProgress,
  clockRemaining,
  clockTone,
  currentGameNo,
  formatTrackerClock,
  groupOps,
  historyGroups,
  inverseOps,
  losingSide,
  makeOp,
  matchDecided,
  matchScore,
  mergeOps,
  openGroup,
  resetOps,
  shownCounters,
  toggleCounter,
  totals,
  undoLast,
  type TrackerClock,
  type TrackerGame,
  type TrackerOp,
} from "./tracker";

const T0 = Date.parse("2026-10-13T18:00:00.000Z");
let n = 0;
const id = () => `op-${++n}`;
const tap = (ms: number, side: 0 | 1, delta: number, counter: TrackerOp["counter"] = "life", game = 1) =>
  makeOp(game, side, counter, delta, T0 + ms, id());
const game = (game_no: number, winner_side: 0 | 1 | null, is_draw = false): TrackerGame => ({
  game_no, winner_side, is_draw, recorded_at: new Date(T0 + game_no * 60_000).toISOString(),
});

describe("change groups", () => {
  it("joins taps less than 2 s apart", () => {
    const ops = [tap(0, 1, -1), tap(800, 1, -1), tap(2700, 1, -1)]; // gaps 0.8 s and 1.9 s
    const groups = groupOps(ops, 1, 20);
    expect(groups).toHaveLength(1);
    expect(groups[0].delta).toBe(-3);
    expect(groups[0].after).toBe(17);
  });

  it("starts a new group after 2 s of quiet", () => {
    const ops = [tap(0, 0, -2), tap(2000, 0, -1), tap(6000, 0, 1)];
    const groups = groupOps(ops, 1, 20);
    expect(groups.map((g) => g.delta)).toEqual([-2, -1, 1]);
    expect(groups.map((g) => g.after)).toEqual([18, 17, 18]);
  });

  it("breaks the group on a different counter or side", () => {
    const ops = [tap(0, 0, -1), tap(300, 0, 1, "poison"), tap(600, 0, -1), tap(900, 1, -1), tap(1200, 1, -1)];
    const groups = groupOps(ops, 1, 20);
    expect(groups.map((g) => [g.side, g.counter, g.delta])).toEqual([
      [0, "life", -1],
      [0, "poison", 1],
      [0, "life", -1],
      [1, "life", -2],
    ]);
  });

  it("orders by tap time, not arrival", () => {
    const ops = [tap(1500, 0, -1), tap(0, 0, -1), tap(5000, 1, -4)];
    const history = historyGroups(ops, 1, 20);
    expect(history.map((g) => g.delta)).toEqual([-4, -2]); // newest first
  });

  it("reports the open group only within the window", () => {
    const ops = [tap(0, 1, -1), tap(500, 1, -1)];
    expect(openGroup(ops, 1, 20, T0 + 1500)?.delta).toBe(-2);
    expect(openGroup(ops, 1, 20, T0 + 2500)).toBeNull();
  });
});

describe("totals", () => {
  it("sums deltas per game from the starting values", () => {
    const ops = [
      tap(0, 0, -5), tap(100, 1, -3), tap(200, 1, 2, "poison"),
      tap(10_000, 0, -7, "life", 2), tap(10_100, 1, 1, "speed", 2),
    ];
    const g1 = totals(ops, 1, 20);
    expect(g1[0].life).toBe(15);
    expect(g1[1].life).toBe(17);
    expect(g1[1].poison).toBe(2);
    const g2 = totals(ops, 2, 20);
    expect(g2[0].life).toBe(13);
    expect(g2[1].life).toBe(20);
    expect(g2[1].poison).toBe(0);
    expect(g2[1].speed).toBe(1);
    expect(totals(ops, 3, 40)[0].life).toBe(40);
  });

  it("clamps bounded counters", () => {
    expect(clampDelta(4, 1, "speed")).toBe(0);
    expect(clampDelta(3, 1, "speed")).toBe(1);
    expect(clampDelta(0, -1, "poison")).toBe(0);
    expect(clampDelta(-3, -1, "life")).toBe(-1);
  });

  it("flags life at 0 or poison at 10", () => {
    expect(losingSide(totals([tap(0, 1, -20)], 1, 20))).toBe(1);
    expect(losingSide(totals([tap(0, 0, 10, "poison")], 1, 20))).toBe(0);
    expect(losingSide(totals([tap(0, 0, -19)], 1, 20))).toBeNull();
  });
});

describe("undo", () => {
  it("produces the inverse op for the newest group", () => {
    const ops = [tap(0, 0, -1), tap(5000, 1, -1), tap(5400, 1, -1), tap(5800, 1, -1)];
    const [group] = historyGroups(ops, 1, 20);
    const inv = inverseOps(group, () => "undo-1");
    expect(inv).toEqual([
      { client_op_id: "undo-1", game_no: 1, side: 1, counter: "life", delta: 3, tapped_at: new Date(T0 + 5800).toISOString(), mine: true },
    ]);
  });

  it("restores the totals and hides the undone group", () => {
    const ops = [tap(0, 0, -2), tap(5000, 1, -3), tap(5300, 1, -2)];
    const after = [...ops, ...undoLast(ops, 1, 20)];
    expect(totals(after, 1, 20)[1].life).toBe(20);
    expect(historyGroups(after, 1, 20).map((g) => [g.side, g.delta])).toEqual([[0, -2]]);
    // A second undo takes the next group back, not the undo itself.
    const twice = [...after, ...undoLast(after, 1, 20)];
    expect(totals(twice, 1, 20)[0].life).toBe(20);
    expect(historyGroups(twice, 1, 20)).toEqual([]);
    expect(undoLast(twice, 1, 20)).toEqual([]);
  });

  it("resets a game with inverse ops", () => {
    const ops = [tap(0, 0, -6), tap(100, 1, 3, "poison"), tap(200, 1, 2, "speed")];
    const reset = resetOps(ops, 1, 20, T0 + 9000);
    const t = totals([...ops, ...reset], 1, 20);
    expect(t[0].life).toBe(20);
    expect(t[1].poison).toBe(0);
    expect(t[1].speed).toBe(0);
  });
});

describe("games", () => {
  it("current game is recorded games + 1", () => {
    expect(currentGameNo([])).toBe(1);
    expect(currentGameNo([game(1, 0)])).toBe(2);
    expect(currentGameNo([game(1, 0), game(2, 1)])).toBe(3);
  });

  it("scores and decides a best of three", () => {
    expect(matchScore([game(1, 0), game(2, null, true)])).toEqual({ wins: [1, 0], draws: 1, played: 2 });
    expect(matchDecided([game(1, 0)])).toBe(false);
    expect(matchDecided([game(1, 1), game(2, 1)])).toBe(true);
    expect(matchDecided([game(1, 0), game(2, 1)])).toBe(false);
    expect(matchDecided([game(1, 0), game(2, 1), game(3, null, true)])).toBe(true);
  });

  it("merges ops by client_op_id", () => {
    const a = tap(0, 0, -1);
    const b = tap(100, 0, -1);
    const merged = mergeOps([a], [{ ...a, mine: false }, b, b]);
    expect(merged.map((o) => o.client_op_id)).toEqual([a.client_op_id, b.client_op_id]);
    expect(merged[0].mine).toBe(true);
  });
});

describe("round clock", () => {
  const clock = (over: Partial<TrackerClock> = {}): TrackerClock => ({
    round_id: "r1",
    timer_status: "running",
    timer_last_started_at: new Date(T0).toISOString(),
    timer_remaining_at_change: 3000,
    timer_duration_seconds: 3000,
    ...over,
  });

  it("counts down from the last start and runs into overtime", () => {
    expect(clockRemaining(clock(), T0 + 1_500)).toBe(2999);
    expect(clockRemaining(clock(), T0 + 3_042_000)).toBe(-42);
  });

  it("holds the value while paused, falling back to the full length", () => {
    expect(clockRemaining(clock({ timer_status: "paused", timer_remaining_at_change: 372 }), T0 + 99_000)).toBe(372);
    expect(clockRemaining(clock({ timer_status: "paused", timer_remaining_at_change: null }), T0)).toBe(3000);
  });

  it("turns amber for the last ten minutes and pink in overtime", () => {
    expect(clockTone(601)).toBe("normal");
    expect(clockTone(600)).toBe("warning");
    expect(clockTone(0)).toBe("warning");
    expect(clockTone(-1)).toBe("overtime");
  });

  it("formats like the design", () => {
    expect(formatTrackerClock(2572)).toBe("42:52");
    expect(formatTrackerClock(372)).toBe("6:12");
    expect(formatTrackerClock(-42)).toBe("+0:42");
    expect(formatTrackerClock(0)).toBe("0:00");
  });

  it("fills the bar with time left, and fully in overtime", () => {
    expect(clockProgress(1500, 3000)).toBe(0.5);
    expect(clockProgress(-5, 3000)).toBe(1);
  });
});

describe("counter columns", () => {
  const values = { life: 20, poison: 0, energy: 0, experience: 0, rad: 0, speed: 0 };

  it("shows counters that were turned on, and any that aren't zero", () => {
    expect(shownCounters(values, { on: ["energy"], off: [] })).toEqual(["energy"]);
    expect(shownCounters({ ...values, poison: 3 }, { on: ["energy"], off: [] })).toEqual(["poison", "energy"]);
  });

  it("keeps a non-zero counter hidden once it's turned off", () => {
    expect(shownCounters({ ...values, poison: 3 }, { on: [], off: ["poison"] })).toEqual([]);
  });

  it("allows three at most", () => {
    const prefs = { on: ["poison", "energy", "rad"] as TrackerOp["counter"][], off: [] };
    const shown = shownCounters(values, prefs);
    expect(toggleCounter(prefs, shown, "speed")).toBe(prefs);
    const off = toggleCounter(prefs, shown, "energy");
    expect(shownCounters(values, off)).toEqual(["poison", "rad"]);
    expect(off.off).toEqual(["energy"]);
  });
});

describe("canRecord (contract/life-tracker-options-2026-10-20.md § After the result is in)", () => {
  it("records while a synced match has no result", () => {
    expect(canRecord({ readOnly: false, synced: true, resultIn: false })).toBe(true);
    expect(canRecord({ readOnly: false, synced: true })).toBe(true); // older servers leave it out
  });
  it("stops once the result is in", () => {
    expect(canRecord({ readOnly: false, synced: true, resultIn: true })).toBe(false);
  });
  it("never records while watching", () => {
    expect(canRecord({ readOnly: true, synced: true, resultIn: false })).toBe(false);
  });
  it("local tables always record", () => {
    expect(canRecord({ readOnly: false, synced: false, resultIn: true })).toBe(true);
  });
});
