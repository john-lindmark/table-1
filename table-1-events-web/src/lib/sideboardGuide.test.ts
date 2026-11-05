import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { check, deckMin, guideFromWire, guideHtml, hasGuide, overSideboard, printModel, setQty, sheets, sideboardCount, uses,
         type GuideLine, type Matchup, type PrintModel } from "./sideboardGuide";

/* Sideboard guides (contract/sideboard-guide-2026-11-04.md) against testdata/sideboard-guide/cases.json, and the
   printed page against guide.html byte for byte; shared with iOS and Android. */

const dir = new URL("../../../testdata/sideboard-guide/", import.meta.url);
const cases = JSON.parse(readFileSync(new URL("cases.json", dir), "utf8"));
const lines: GuideLine[] = cases.lines;
const guide = guideFromWire(cases.guide)!;

describe("sideboard guide", () => {
  it("formats", () => {
    for (const [f, want] of Object.entries(cases.has_guide)) expect(hasGuide(f), f).toBe(want);
    for (const [f, want] of Object.entries(cases.deck_min)) expect(deckMin(f), f).toBe(want);
  });
  it("checks each matchup", () => {
    for (const c of cases.check) {
      const m = guide.matchups.find((x) => x.id === c.matchup) ?? { in: c.in, out: c.out };
      expect(check(m, lines, c.format), `${c.matchup} ${c.format}`).toEqual(c.expect);
    }
  });
  it("sideboard size and uses", () => {
    expect(sideboardCount(lines)).toBe(cases.sideboard_count);
    for (const c of cases.over_sideboard) expect(overSideboard(c.lines, c.format)).toBe(c.expect);
    expect(uses(guide)).toEqual(cases.uses);
  });
  it("keeps the order cards were added", () => {
    let m: Matchup = { id: "a", name: "A", in: [], out: [], notes: "" };
    m = setQty(setQty(setQty(m, "x", 2, "in"), "y", 1, "in"), "x", 3, "in");
    expect(m.in).toEqual([["x", 3], ["y", 1]]);
    expect(setQty(m, "x", 0, "in").in).toEqual([["y", 1]]);
  });
  it("prints only what can come in, as guide.html", () => {
    const r = printModel("Izzet Murktide", "Modern", "2026-11-04", lines, guide, "modern");
    expect(r.model).toEqual(cases.print.model);
    expect(r.warnings).toEqual(cases.print.warnings);
    expect(r.sheets).toBe(cases.print.sheets);
    expect(guideHtml(r.model)).toBe(readFileSync(new URL("guide.html", dir), "utf8"));
  });
  it("estimates sheets", () => {
    for (const c of cases.sheets) {
      const m: PrintModel = { deck: "", format: "", date: "", sideboard: Array(15).fill([1, "x"]),
        matchups: Array(c.matchups).fill({ name: "m", in: Array(5).fill([1, "a"]), out: Array(5).fill([1, "b"]), notes: "x".repeat(120) }) };
      expect(sheets(m), String(c.matchups)).toBe(c.expect);
    }
  });
  it("reads no guide as null", () => {
    expect(guideFromWire(null)).toBeNull();
    expect(guideFromWire({ matchups: [] })).toBeNull();
  });
});
