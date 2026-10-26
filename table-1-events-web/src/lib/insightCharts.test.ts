import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { delta, fit, heat, months, pct, pct1, segments, spread, ticks, wilson } from "./insightCharts";

/* Every answer comes from testdata/insight-charts/cases.json (the Python reference); iOS and Android read it too. */
const cases = JSON.parse(readFileSync(new URL("../../../testdata/insight-charts/cases.json", import.meta.url), "utf8"));

describe("insight charts", () => {
  it("ticks", () => {
    for (const c of cases.ticks) {
      const got = ticks(c.in[0], c.in[1], c.in[2]);
      expect(got.length).toBe(c.out.length);
      got.forEach((v, i) => expect(v).toBeCloseTo(c.out[i], 9));
    }
  });
  it("segments", () => { for (const c of cases.segments) expect(segments(c.in)).toEqual(c.out); });
  it("heat", () => {
    for (const c of cases.heat) expect(heat(c.in[0], c.in[1]), JSON.stringify(c.in)).toEqual(c.out);
  });
  it("wilson", () => {
    for (const c of cases.wilson) {
      const [lo, hi] = wilson(c.in[0], c.in[1]);
      expect(lo).toBeCloseTo(c.out[0], 6);
      expect(hi).toBeCloseTo(c.out[1], 6);
    }
  });
  it("fit", () => {
    for (const c of cases.fit) {
      const f = fit(c.in[0], c.in[1]);
      if (c.out == null) expect(f).toBeNull();
      else { expect(f!.a).toBeCloseTo(c.out.a, 7); expect(f!.b).toBeCloseTo(c.out.b, 7); }
    }
  });
  it("spread", () => {
    for (const c of cases.spread) {
      const got = spread(c.in[0], c.in[1], c.in[2], c.in[3]);
      expect(got.length).toBe(c.out.length);
      got.forEach((v, i) => expect(v).toBeCloseTo(c.out[i], 6));
    }
  });
  it("labels", () => {
    for (const c of cases.pct) expect(pct(c.in)).toBe(c.out);
    for (const c of cases.pct1) expect(pct1(c.in)).toBe(c.out);
    for (const c of cases.delta) expect(delta(c.in)).toBe(c.out);
  });
  it("months", () => { for (const c of cases.months) expect(months(c.in[0], c.in[1])).toEqual(c.out); });
});
