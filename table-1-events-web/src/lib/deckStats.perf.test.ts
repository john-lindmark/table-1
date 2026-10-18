import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  StatsRng, asfan, averageMV, colorBalance, curve, curveByColor, legality, pipTotals, sources, statCard, typeCounts, type AsfanBy,
  type StatCard,
} from "./deckStats";

/* Budget: every stat on a 540-card cube (and the same cards read as a deck), as the Stats screen computes them on
   open. Same work as iOS DeckStatsTests.testPerfCube540 and Android DeckStatsTest. The budget applies under
   T1_PERF=1 (./test.sh perf); the fast tier only checks it runs. */

const BUDGET_MS = 5;
const perf = process.env.T1_PERF === "1";

const cases = JSON.parse(readFileSync(new URL("../../../testdata/deck-stats/cases.json", import.meta.url), "utf8")) as {
  cube: { cards: Omit<StatCard, "typeBits">[] };
};

describe("deck stats perf", () => {
  it("540-card cube", () => {
    const base = cases.cube.cards.filter((c) => c.board === "main");
    const cube = Array.from({ length: 540 }, (_, i) => statCard({ ...base[i % base.length], name: `${base[i % base.length].name} ${i}` }));
    const all = () => {
      colorBalance(cube);
      curveByColor(cube);
      typeCounts(cube);
      for (const by of ["color", "type", "mv"] as AsfanBy[]) asfan(cube, 15, by);
      curve(cube);
      pipTotals(cube);
      sources(cube);
      averageMV(cube, false);
      legality(cube, "vintage");
      new StatsRng(5).shuffle(540);
    };
    all();
    const runs = 20;
    const t0 = performance.now();
    for (let i = 0; i < runs; i++) all();
    const ms = (performance.now() - t0) / runs;
    console.log(`perf web cube stats 540 cards: ${ms.toFixed(1)} ms (budget ${BUDGET_MS})`);
    if (perf) expect(ms).toBeLessThan(BUDGET_MS);
  });
});
