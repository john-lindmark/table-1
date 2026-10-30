import { describe, expect, it } from "vitest";
import { TableLayout } from "./tableLayout";

/* Draft seating drawn as one long table (contract/event-night-2026-10-16.md § 3), as iOS TableLayout and Android
   TableLayoutTest. */
describe("TableLayout", () => {
  it("seats the sides only by default", () => {
    const t = new TableLayout(8, false);
    expect([t.right, t.left, t.ends]).toEqual([4, 4, false]);
    const p = t.positions(360, 120);
    // Seat 1 at the top of the right side, down the right, then up the left: seat 8 top left, across from seat 1.
    expect(p[0].x > 180 && p[3].x > 180 && p[4].x < 180).toBe(true);
    expect(p[0].y < p[3].y && p[4].y > p[7].y).toBe(true);
    expect(p[7].y).toBeCloseTo(p[0].y);
  });
  it("needs four players for the ends, and takes the head and the foot", () => {
    expect(new TableLayout(3, true).ends).toBe(false);
    const t = new TableLayout(8, true);
    expect([t.right, t.left, t.ends]).toEqual([3, 3, true]);
    const p = t.positions(360, 120);
    expect(p[0].x).toBeCloseTo(180);
    expect(p[4].x).toBeCloseTo(180);
    expect(p[4].y > p[3].y).toBe(true);
    expect(new TableLayout(8, true).height > new TableLayout(8, false).height).toBe(true);
  });
  it("puts an odd side's extra player on the right", () => {
    const t = new TableLayout(7, false);
    expect([t.right, t.left]).toEqual([4, 3]);
  });
});
