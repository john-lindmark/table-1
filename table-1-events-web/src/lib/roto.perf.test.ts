import { describe, expect, it } from "vitest";
import { mergePicks, pickNoAt, seatFor, type RotoPick } from "./rotoMath";

// The roto Draft's hot paths at the largest sheet the contract plans for (12 seats × 45 rounds = 540 picks).
// Always checks the results; with T1_PERF=1 (./test.sh perf) also enforces time budgets. Budgets sit well above
// a Mac's timings so they catch an accidental quadratic pass, not noise.
const PERF = !!process.env.T1_PERF;
const SEATS = 12;
const ROUNDS = 45;
const TOTAL = SEATS * ROUNDS;

const pick = (n: number): RotoPick => ({ pickNo: n, seat: seatFor(SEATS, n, true), slot: n, how: "player", at: 0 });

describe("roto perf", () => {
  it("a whole draft arrives as one-pick deltas", () => {
    const t0 = performance.now();
    let held: RotoPick[] = [];
    for (let n = 1; n <= TOTAL; n++) {
      const r = mergePicks(held, [pick(n)], n);
      expect(r.needsFull).toBe(false);
      held = r.picks;
    }
    const ms = performance.now() - t0;
    console.log(`perf web roto: ${TOTAL} delta merges ${ms.toFixed(1)} ms`);
    expect(held).toHaveLength(TOTAL);
    if (PERF) expect(ms).toBeLessThan(400);
  });

  it("every grid cell finds its pick", () => {
    const picks = Array.from({ length: TOTAL }, (_, i) => pick(i + 1));
    const t0 = performance.now();
    let found = 0;
    for (let rep = 0; rep < 60; rep++) {
      for (let r = 1; r <= ROUNDS; r++) {
        for (let s = 1; s <= SEATS; s++) {
          const no = pickNoAt(s, r, SEATS, true);
          if (picks[no - 1]?.pickNo === no && picks[no - 1].seat === s) found++;
        }
      }
    }
    const ms = (performance.now() - t0) / 60;
    console.log(`perf web roto: grid lookup ${ms.toFixed(2)} ms per full sheet`);
    expect(found).toBe(TOTAL * 60);
    if (PERF) expect(ms).toBeLessThan(4);
  });
});
