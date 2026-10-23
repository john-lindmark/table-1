import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  Knowledge, RankingState, compare, diffPlaces, disagreements, expectedMerge, expectedSort, fnv1a, members, pack, pickWins, reaskOpen, why,
  type RankDepth, type RankJob, type RankScreen, type RankSession,
} from "./cubeRanking";

/* Cube rankings engine (contract/cube-rankings-2026-10-21.md) against the shared cases in
   testdata/cube-ranking/cases.json, written by the reference make_cases.py; iOS CubeRankingTests and Android
   CubeRankingTest read the same file. */

type Summary = Record<string, { top: string[]; done: boolean; target: number; size: number; screens: number; question: string[] | null; pinned: string[] | null; waiting: string[] }>;
interface Step { s: RankJob; at: number; question: string[]; pinned: string[]; answer: string[]; pack?: string[]; disagree?: string[] }
interface Run { id: string; depth: RankDepth; top: number; steps: Step[]; summary: Summary; contradicted?: Record<string, [string, string][]> }
type ChangeRow = [string, string, number | null, number | null];
type Row = [string, number, boolean, number, boolean, number, boolean];
interface Cases {
  cube: { cards: string[]; category: Record<string, RankJob> };
  runs: Run[];
  compare: Record<string, { compared: number; avgTenths: number; atLeast: boolean; biggest: Row[]; oneSide: Row[] }>;
  why: { hi: string; lo: string; chain: [string, string, number][] | null }[];
  redo: { remove: number; changesNothing: boolean; session: RankJob; reaskOpen: boolean; after: Summary; changes: ChangeRow[] }[];
  pickWins: { at: number; pack: string[]; picked: string; disagree: string[]; removed: number[]; after: Summary; changes: ChangeRow[] };
  edge: { log: RankScreen[]; known: [string, string][] };
  cubeChange: { id: string; depth: RankDepth; top: number; removed: string[]; added: Record<string, RankJob>; new: string[];
                before: Summary; after: Summary; changes: ChangeRow[]; steps: (Step & { waiting: string[]; top: string[] })[] };
  estimates: { sort: [number, number, number][]; merge: [number[], number, number][] };
}
const cases: Cases = JSON.parse(readFileSync(new URL("../../../testdata/cube-ranking/cases.json", import.meta.url), "utf8"));
const cards = new Map(Object.entries(cases.cube.category));
const logOf = (r: Run): RankScreen[] => r.steps.map((s) => ({ s: s.s, o: s.answer }));
const stateOf = (r: Run, log: RankScreen[]) => new RankingState(r.id, cards, log, r.depth, r.top);

function checkSummary(st: RankingState, want: Summary) {
  expect(new Set([...st.jobs, "F"])).toEqual(new Set(Object.keys(want)));
  for (const [key, w] of Object.entries(want)) {
    const s = st.session(key as RankJob);
    expect({ key, top: s.top.map((x) => st.id(x)), done: s.done, target: s.target, size: s.size,
             screens: st.knowledge.perJob[key as RankJob] ?? 0, question: s.question?.map((x) => st.id(x)) ?? null,
             pinned: s.question ? s.pinned.map((x) => st.id(x)) : null, waiting: s.waiting.map((x) => st.id(x)) })
      .toEqual({ key, top: w.top, done: w.done, target: w.target, size: w.size, screens: w.screens, question: w.question, pinned: w.pinned,
                 waiting: w.waiting });
  }
}

const changeRow = (c: { s: string; c: string; f: number | null; to: number | null }): ChangeRow => [c.s, c.c, c.f, c.to];
const gapRow = (g: { card: string; a: number; aOut: boolean; b: number; bOut: boolean; gap: number; atLeast: boolean }): Row =>
  [g.card, g.a, g.aOut, g.b, g.bOut, g.gap, g.atLeast];

describe("replaying each run screen by screen", () => {
  for (const run of cases.runs) {
    it(run.id, () => {
      let st = stateOf(run, []);
      for (const step of run.steps) {
        expect(st.knowledge.screens).toBe(step.at);
        if (step.s === "P") {
          const pk = pack(run.id, st.knowledge);
          expect(pk).toEqual(step.pack);
          expect(disagreements(st.knowledge, step.answer[0], pk)).toEqual(step.disagree);
          st = st.appending({ s: "P", o: step.answer });
          continue;
        }
        const s = st.session(step.s);
        expect(s.question?.map((x) => st.id(x))).toEqual(step.question);
        expect(s.pinned.map((x) => st.id(x))).toEqual(step.pinned);
        st = st.appending({ s: step.s, o: step.answer });
      }
      checkSummary(st, run.summary);
      checkSummary(stateOf(run, logOf(run)), run.summary);
      if (run.contradicted) {
        const got = Object.fromEntries([...st.knowledge.contradicted].map(([k, v]) => [String(k), v.map(([w, l]) => [st.id(w), st.id(l)])]));
        expect(got).toEqual(run.contradicted);
      }
    });
  }
});

describe("compare", () => {
  const [ra, rb] = cases.runs;
  const a = stateOf(ra, logOf(ra)), b = stateOf(rb, logOf(rb));
  for (const [key, want] of Object.entries(cases.compare)) {
    it(key, () => {
      const job = key as RankJob;
      const c = compare(a.knowledge, a.session(job), b.session(job), a.scope(job));
      expect({ compared: c.compared, avgTenths: c.avgTenths, atLeast: c.atLeast, biggest: c.biggest.map(gapRow), oneSide: c.oneSide.map(gapRow) })
        .toEqual(want);
    });
  }
});

describe("why, redo and edge cases", () => {
  const run = cases.runs[0];
  const log = logOf(run);
  const full = stateOf(run, log);
  it("why chains", () => {
    for (const w of cases.why) {
      expect(why(full.knowledge, log, w.hi, w.lo)?.map((l) => [l.winner, l.loser, l.screen]) ?? null).toEqual(w.chain);
    }
  });
  for (const r of cases.redo) {
    it(`redo screen ${r.remove}`, () => {
      const rest = log.filter((_, i) => i !== r.remove);
      const st = stateOf(run, rest);
      expect(st.knowledge.same(full.knowledge)).toBe(r.changesNothing);
      const s: RankSession = st.session(r.session);
      expect(reaskOpen(st.knowledge, s, log[r.remove].o)).toBe(r.reaskOpen);
      checkSummary(st, r.after);
      expect(diffPlaces(full.places(), st.places()).map(changeRow)).toEqual(r.changes);
    });
  }
  it("let the pick win", () => {
    const runC = cases.runs[2], w = cases.pickWins;
    const logC = logOf(runC);
    const st = stateOf(runC, logC);
    expect(st.knowledge.screens).toBe(w.at);
    const pk = pack(runC.id, st.knowledge);
    expect(pk).toEqual(w.pack);
    expect(disagreements(st.knowledge, w.picked, pk)).toEqual(w.disagree);
    const removed = pickWins([...cards.keys()], logC, w.picked, pk);
    expect(removed).toEqual(w.removed);
    const after = stateOf(runC, [...logC.filter((_, i) => !removed.includes(i)), { s: "P", o: [w.picked, ...pk.filter((c) => c !== w.picked)] }]);
    checkSummary(after, w.after);
    expect(diffPlaces(st.places(), after.places()).map(changeRow)).toEqual(w.changes);
  });
  it("a contradiction and a card that left the cube", () => {
    const K = new Knowledge([...cards.keys()], cases.edge.log);
    const known: [string, string][] = [];
    for (let x = 0; x < K.size; x++) for (const y of members(K.beats[x])) known.push([K.ids[x], K.ids[y]]);
    known.sort((p, q) => (p[0] < q[0] ? -1 : p[0] > q[0] ? 1 : p[1] < q[1] ? -1 : p[1] > q[1] ? 1 : 0));
    expect(known).toEqual(cases.edge.known);
  });
});

describe("when the cube changes", () => {
  const cc = cases.cubeChange;
  const run = cases.runs.find((r) => r.id === cc.id)!;
  const cube = new Map([...cards].filter(([c]) => !cc.removed.includes(c)).concat(Object.entries(cc.added)));
  const at = (log: RankScreen[]) => new RankingState(cc.id, cube, log, cc.depth, cc.top, undefined, cc.new);
  it("removed cards leave the lists, new ones wait, and the order holds", () => {
    checkSummary(at(logOf(run)), cc.before);
    expect(at(logOf(run)).waiting).toEqual([...cc.new].sort());
  });
  it("re-ranking asks only what it must and every list stays in place", () => {
    const log = logOf(run);
    let st = at(log);
    for (const step of cc.steps) {
      const s = st.session(step.s);
      expect([s.question?.map((x) => st.id(x)), s.pinned.map((x) => st.id(x)), s.waiting.map((x) => st.id(x)), s.top.map((x) => st.id(x))])
        .toEqual([step.question, step.pinned, step.waiting, step.top]);
      st = st.appending({ s: step.s, o: step.answer });
      log.push({ s: step.s, o: step.answer });
    }
    checkSummary(at(log), cc.after);
    expect(at(log).waiting).toEqual([]);
    expect(diffPlaces(at(logOf(run)).places(), at(log).places()).map(changeRow)).toEqual(cc.changes);
  });
});

describe("estimates", () => {
  for (const [n, k, want] of cases.estimates.sort) it(`sort ${n} top ${k}`, () => expect(Math.abs(expectedSort(n, k) - want)).toBeLessThanOrEqual(1));
  for (const [sizes, t, want] of cases.estimates.merge) it(`merge ${sizes.join(",")} top ${t}`, () => expect(Math.abs(expectedMerge(sizes, t) - want)).toBeLessThanOrEqual(1));
  it("fnv1a", () => {
    expect(fnv1a("")).toBe(0x811c9dc5);
    expect(fnv1a("a")).toBe(0xe40c292c);
  });
});
