import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { cubeCobraId, cubeSyncDiff, syncSummary, type SyncPrinting } from "./cubeSync";
import type { Condition } from "./collection";
import { entry, fromWire, type Board, type Entry, type ListFinish } from "./lists";

/* Sync a cube with Cube Cobra against testdata/cube-sync/cases.json (also iOS CubeSyncTests and Android CubeSyncTest). */

type Wire = [string, Board, number, ListFinish?, string?, Condition?];
interface Case { name: string; current: Wire[]; incoming: Wire[]; want: Record<string, unknown> & { entries: Wire[] }; summary: string }
const { printings, cases }: { printings: Record<string, SyncPrinting>; cases: Case[] } =
  JSON.parse(readFileSync(new URL("../../../testdata/cube-sync/cases.json", import.meta.url), "utf8"));
const toEntry = ([c, b, q, f, l, k]: Wire): Entry => entry(c, b, q, f ?? "nonfoil", l ?? "en", k ?? "NM");

describe("cubeSyncDiff", () => {
  it("has cases", () => expect(cases.length).toBeGreaterThan(0));
  for (const c of cases) {
    it(c.name, () => {
      const r = cubeSyncDiff(c.current.map(toEntry), c.incoming.map(toEntry), (id) => printings[id]);
      expect(r.in).toEqual(c.want.in);
      expect(r.out).toEqual(c.want.out);
      expect(r.changed).toEqual(c.want.changed);
      expect(r.same).toBe(c.want.same);
      expect(r.entries).toEqual(c.want.entries.map(toEntry));
      expect(syncSummary(r)).toBe(c.summary);
    });
  }
});

describe("cubeCobraId", () => {
  it("reads the id from Cube Cobra links only", () => {
    expect(cubeCobraId("https://cubecobra.com/cube/list/lindmark")).toBe("lindmark");
    expect(cubeCobraId("cubecobra.com/cube/overview/abc-1")).toBe("abc-1");
    expect(cubeCobraId("https://www.cubecobra.com/c/xyz")).toBe("xyz");
    expect(cubeCobraId("https://moxfield.com/decks/abc")).toBeNull();
    expect(cubeCobraId(null)).toBeNull();
  });
});

describe("fromWire", () => {
  it("keeps the seq and the link", () => {
    const l = fromWire({ id: "a", kind: "cube", name: "C", format: "vintage", seq: 7, source_url: "https://cubecobra.com/cube/list/a",
                         versions: [{ version: 1, note: "x", at: 0, entries: [] }] });
    expect(l?.seq).toBe(7);
    expect(l?.sourceUrl).toBe("https://cubecobra.com/cube/list/a");
  });
});
