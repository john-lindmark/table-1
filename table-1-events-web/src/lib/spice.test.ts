import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  SPICE_WORDS, demoSpice, spiceBasis, spiceCardLine, spiceCubes, spiceHeadline, spiceMissingLine, spiceReason, spiceSummary,
  type SpiceResult,
} from "./spice";

/* Spice (contract/spice-2026-10-28.md) against testdata/spice/cases.json (make_cases.py), which iOS and Android read too:
   every case's server answer shows exactly the case's `display`. */

const data = JSON.parse(readFileSync(new URL("../../../testdata/spice/cases.json", import.meta.url), "utf8"));

describe("spice", () => {
  it("shows every case's display", () => {
    expect(data.cases.length).toBeGreaterThan(10);
    for (const c of data.cases) {
      const r = c.expect as SpiceResult, d = c.display;
      expect(spiceSummary(r), c.name).toBe(d.summary);
      expect(spiceHeadline(r), c.name).toBe(d.headline);
      expect(spiceBasis(r), c.name).toBe(d.basis);
      expect(spiceCubes(r), c.name).toEqual(d.cubes);
      expect(r.cards.map((x) => spiceCardLine(x, r)), c.name).toEqual(d.cards);
      expect(r.stock_missing.map((m) => spiceMissingLine(m, r)), c.name).toEqual(d.missing);
      expect(spiceReason(r), c.name).toBe(d.reason);
    }
  });

  it("names every word", () => {
    for (const w of data.words) expect(SPICE_WORDS[w.word]).toBe(w.label);
  });

  it("makes a demo result without basics", () => {
    const cards = Array.from({ length: 8 }, (_, i) => ({ oracleId: `o${i}`, name: `Card ${i}`, qty: 4, board: "main", basic: false }));
    const r = demoSpice([...cards, { oracleId: "b", name: "Island", qty: 20, board: "main", basic: true }], "deck", "modern");
    expect(r.score).not.toBeNull();
    expect(r.cards.some((c) => c.n === "Island")).toBe(false);
  });
});
