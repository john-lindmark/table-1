import { readFileSync } from "node:fs";
import vm from "node:vm";
import { describe, expect, it } from "vitest";
import { RULES, fnv1a } from "./cubeRanking";
import { API, T1Rank } from "./rankEngine";
import selfCase from "./rankEngineSelfTest.json";

/* The engine as a file the apps download (contract/cube-rankings-2026-10-21.md § The engine as a file). The build
   (tools/rank-engine/build.mjs) replays every shared case through the built file; these keep the source honest. */

const casesUrl = new URL("../../../testdata/cube-ranking/cases.json", import.meta.url);
const cases = JSON.parse(readFileSync(casesUrl, "utf8"));

describe("rank engine file", () => {
  it("carries the reference's rules and api 1", () => {
    expect(RULES).toBe(cases.rules);
    expect(T1Rank.rules).toBe(cases.rules);
    expect(API).toBe(1);
  });

  it("passes its self test, which is run D of the shared cases", () => {
    const d = cases.runs.find((r: { id: string }) => r.id.endsWith("000d"));
    expect(selfCase.steps.length).toBe(d.steps.length);
    expect(selfCase.final).toEqual(d.summary.F.top);
    expect(T1Rank.selfTest()).toBe(true);
  });

  it("answers sessions with card ids", () => {
    const run = cases.runs[0];
    const h = T1Rank.open(JSON.stringify({ id: run.id, cards: cases.cube.category, log: [], depth: run.depth, top: run.top }));
    const s = JSON.parse(T1Rank.session(h, run.steps[0].s));
    expect(s.question).toEqual(run.steps[0].question);
    expect(s.open.every((c: string) => typeof c === "string")).toBe(true);
    const h2 = T1Rank.append(h, JSON.stringify({ s: run.steps[0].s, o: run.steps[0].answer }));
    expect(JSON.parse(T1Rank.session(h2, run.steps[1].s)).question).toEqual(run.steps[1].question);
    T1Rank.free(h); T1Rank.free(h2);
    expect(() => T1Rank.session(h, "F")).toThrow();
  });

  it("hashes UTF-8 without TextEncoder, the same bytes as before", () => {
    const old = (s: string) => { let h = 0x811c9dc5; for (const b of new TextEncoder().encode(s)) { h ^= b; h = Math.imul(h, 0x01000193) >>> 0; } return h >>> 0; };
    for (const s of ["", "a1b2c3d4-0000-4000-8000-00000000000a:F:12:x", "Æther Vial", "Lim-Dûl", "敵対", "🂡 card"]) expect(fnv1a(s)).toBe(old(s));
  });

  it("the committed file the apps test with runs in a bare context and matches the source's rules", () => {
    const code = readFileSync(new URL("../../../testdata/cube-ranking/rank-engine.js", import.meta.url), "utf8");
    const ctx = vm.createContext({});
    vm.runInContext(code, ctx);
    expect(ctx.T1Rank.rules).toBe(RULES);
    expect(ctx.T1Rank.selfTest()).toBe(true);
  });
});
