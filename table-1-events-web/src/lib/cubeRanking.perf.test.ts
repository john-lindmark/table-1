import { describe, expect, it } from "vitest";
import { COLOR_JOBS, RankingState, type RankJob, type RankScreen } from "./cubeRanking";

/* Budgets (contract/cube-rankings-2026-10-21.md): a 540-card cube ranked the whole way (top half of each color, then
   the top 100, ~550 screens). Opening a ranking rebuilds it from the log; each lock-in appends one screen and works out
   the next screen plus the two lists it can move (its color and the final). The budgets apply under T1_PERF=1
   (./test.sh perf); the fast tier only checks it runs. */

const OPEN_MS = 100;
const LOCK_IN_MS = 15;
const perf = process.env.T1_PERF === "1";

function cube() {
  const cards = new Map<string, RankJob>();
  for (let i = 0; i < 540; i++) cards.set(`00000000-0000-4000-8000-${String(i).padStart(12, "0")}`, COLOR_JOBS[i % 8]);
  return cards;
}
const truth = (id: string) => Math.imul(Number(id.slice(-6)) + 7, 2654435761) >>> 0;

describe("cube ranking perf", () => {
  const cards = cube();
  let st = new RankingState("perf", cards, [], "half", 100);
  const log: RankScreen[] = [];
  const lockIns: number[] = [];
  for (const job of [...st.jobs, "F" as RankJob]) {
    for (let q = st.session(job).question; q; q = st.session(job).question) {
      const t0 = performance.now();
      const s: RankScreen = { s: job, o: q.map((x) => st.id(x)).sort((a, b) => truth(a) - truth(b)) };
      log.push(s);
      const next = st.appending(s);
      next.places(job === "F" ? undefined : [job, "F"]);
      st.places(job === "F" ? undefined : [job, "F"]);
      next.session(job);
      st = next;
      lockIns.push(performance.now() - t0);
    }
  }

  it("ranks the whole cube", () => {
    expect(st.session("F").done).toBe(true);
    expect(log.length).toBeGreaterThan(400);
  });

  it("opening a finished ranking", () => {
    const t0 = performance.now();
    const again = new RankingState("perf", cards, log, "half", 100);
    for (const j of [...again.jobs, "F" as RankJob]) again.session(j);
    const ms = performance.now() - t0;
    console.log(`perf web cube ranking open 540 cards, ${log.length} screens: ${ms.toFixed(1)} ms (budget ${OPEN_MS})`);
    if (perf) expect(ms).toBeLessThan(OPEN_MS);
  });

  it("a lock-in", () => {
    const sorted = lockIns.slice().sort((a, b) => a - b);
    const p95 = sorted[Math.floor(sorted.length * 0.95)];
    console.log(`perf web cube ranking lock-in p95: ${p95.toFixed(1)} ms (budget ${LOCK_IN_MS})`);
    if (perf) expect(p95).toBeLessThan(LOCK_IN_MS);
  });
});
