import { describe, expect, it } from "vitest";
import {
  CHOOSER_SETTLE_MS,
  DICE_SIDES,
  MAX_DICE,
  chooserDown,
  chooserMove,
  chooserProgress,
  chooserTick,
  chooserUp,
  diceBreakdown,
  emptyChooser,
  rollDice,
  type ChooserState,
} from "./trackerTools";

/** mulberry32, so every run rolls and picks the same. */
function seeded(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

describe("rollDice", () => {
  it("stays on its faces and covers them all", () => {
    const random = seeded(1);
    for (const sides of DICE_SIDES) {
      const seen = new Set<number>();
      for (let i = 0; i < 200; i++) {
        const rolls = rollDice(sides, 3, random);
        expect(rolls).toHaveLength(3);
        for (const r of rolls) {
          expect(r).toBeGreaterThanOrEqual(1);
          expect(r).toBeLessThanOrEqual(sides);
          seen.add(r);
        }
      }
      expect(seen.size).toBe(sides);
    }
  });

  it("clamps the count", () => {
    expect(rollDice(6, 0, seeded(2))).toHaveLength(1);
    expect(rollDice(6, 99, seeded(2))).toHaveLength(MAX_DICE);
  });

  it("breaks down only several dice", () => {
    expect(diceBreakdown([17])).toBeNull();
    expect(diceBreakdown([3, 5, 1])).toBe("3 + 5 + 1");
  });
});

describe("chooser", () => {
  const t0 = 1_000_000;
  const down = (s: ChooserState, id: number, at: number) => chooserDown(s, id, 0, 0, at);

  it("picks two seconds after the last finger lands", () => {
    const random = seeded(3);
    let s = down(emptyChooser(), 1, t0);
    expect(chooserProgress(s, t0 + 5000)).toBeNull();
    expect(chooserTick(s, t0 + 5000, random).winner).toBeNull();
    s = down(s, 2, t0 + 1000);
    expect(chooserTick(s, t0 + 2900, random).winner).toBeNull();
    expect(chooserProgress(s, t0 + 2000)).toBeCloseTo(0.5);
    s = chooserTick(s, t0 + 1000 + CHOOSER_SETTLE_MS, random);
    expect([1, 2]).toContain(s.winner);
    expect(chooserTick(s, t0 + 9000, random)).toBe(s);
  });

  it("doesn't restart the wait when a finger moves", () => {
    let s = down(down(emptyChooser(), 1, t0), 2, t0);
    s = chooserMove(s, 1, 40, 40);
    expect(s.fingers[0]).toEqual({ id: 1, x: 40, y: 40 });
    expect(chooserTick(s, t0 + 2000, seeded(4)).winner).not.toBeNull();
  });

  it("restarts the wait when a finger lifts before the pick", () => {
    let s = emptyChooser();
    for (const id of [1, 2, 3]) s = down(s, id, t0);
    s = chooserUp(s, 3, t0 + 1500);
    expect(s.fingers.map((f) => f.id)).toEqual([1, 2]);
    expect(chooserTick(s, t0 + 3000, seeded(5)).winner).toBeNull();
    expect(chooserTick(s, t0 + 3500, seeded(5)).winner).not.toBeNull();
  });

  it("ignores new fingers after the pick until everyone lifts", () => {
    let s = chooserTick(down(down(emptyChooser(), 1, t0), 2, t0), t0 + 2000, seeded(6));
    s = down(s, 3, t0 + 2500);
    expect(s.fingers).toHaveLength(2);
    s = chooserUp(s, 1, t0 + 3000);
    expect(s.winner).not.toBeNull();
    expect(s.fingers).toHaveLength(2);
    s = chooserUp(s, 3, t0 + 3000);
    expect(s.winner).not.toBeNull();
    s = chooserUp(s, 2, t0 + 3200);
    expect(s).toEqual(emptyChooser());
  });

  it("lets every finger win", () => {
    const random = seeded(7);
    const winners = new Set<number>();
    for (let i = 0; i < 100; i++) {
      let s = emptyChooser();
      for (const id of [1, 2, 3, 4]) s = down(s, id, t0);
      const w = chooserTick(s, t0 + 2000, random).winner;
      if (w != null) winners.add(w);
    }
    expect([...winners].sort()).toEqual([1, 2, 3, 4]);
  });
});
