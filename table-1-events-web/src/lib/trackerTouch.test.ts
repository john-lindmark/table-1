import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  farFrom,
  holds,
  inPullBand,
  pulls,
  TOUCH_BAND,
  TOUCH_HOLD_SLOP,
  TOUCH_MOVED,
  TOUCH_SWIPE,
  type Seat,
} from "./trackerTable";

// contract/life-tracker-options-2026-10-20.md § Taps and the pull band: a tap always counts however far it
// drifts; only a touch that starts in the band along the player's far edge and travels toward them opens the
// counter picker.
type Touch = {
  note: string;
  seat: Seat;
  box: [number, number];
  start: [number, number];
  move: [number, number];
  far: number;
  band: boolean;
  pull: boolean;
  holds: boolean;
};
const cases = JSON.parse(
  readFileSync(new URL("../../../testdata/tracker-touch/cases.json", import.meta.url), "utf8"),
) as { band: number; swipe: number; holdSlop: number; moved: number; touches: Touch[] };

describe("tracker touches", () => {
  it("uses the shared constants", () => {
    expect([TOUCH_BAND, TOUCH_SWIPE, TOUCH_HOLD_SLOP, TOUCH_MOVED]).toEqual([
      cases.band,
      cases.swipe,
      cases.holdSlop,
      cases.moved,
    ]);
  });

  for (const t of cases.touches) {
    it(t.note, () => {
      const [w, h] = t.box;
      const [x, y] = t.start;
      const [dx, dy] = t.move;
      expect(farFrom(t.seat, x, y, w, h)).toBe(t.far);
      expect(inPullBand(t.seat, x, y, w, h)).toBe(t.band);
      expect(pulls(t.seat, x, y, w, h, dx, dy)).toBe(t.pull);
      expect(holds(dx, dy)).toBe(t.holds);
    });
  }
});
