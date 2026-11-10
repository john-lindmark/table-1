import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { FOLD, foldFromSegments, foldLayout, type Fold } from "./fold";

/* Fold-aware layouts (contract/foldables-2026-11-10.md) against testdata/foldables/cases.json, which iOS and Android read too. */
const data = JSON.parse(readFileSync(new URL("../../../testdata/foldables/cases.json", import.meta.url), "utf8"));

describe("foldLayout", () => {
  it("shares its constants with the reference", () => {
    expect(FOLD).toEqual(data.constants);
  });

  for (const c of data.cases as { name: string; w: number; h: number; folds: Fold[]; out: unknown }[]) {
    it(c.name, () => {
      expect(foldLayout(c.w, c.h, c.folds)).toEqual(c.out);
    });
  }
});

describe("foldFromSegments", () => {
  const seg = (left: number, top: number, width: number, height: number) => ({
    left, top, width, height, right: left + width, bottom: top + height,
  });

  it("reads nothing from one segment or none", () => {
    expect(foldFromSegments(null)).toEqual([]);
    expect(foldFromSegments([seg(0, 0, 841, 673)])).toEqual([]);
  });

  it("stacked segments are a horizontal fold: tabletop", () => {
    const folds = foldFromSegments([seg(0, 0, 841, 336), seg(0, 340, 841, 333)]);
    expect(folds).toEqual([{ x: 0, y: 336, w: 841, h: 4, vertical: false, separating: true, margin: 0 }]);
    expect(foldLayout(841, 673, folds).mode).toBe("tabletop");
  });

  it("side-by-side segments are a vertical fold: book", () => {
    const folds = foldFromSegments([seg(0, 0, 336, 841), seg(337, 0, 336, 841)]);
    expect(folds[0]).toMatchObject({ x: 336, w: 1, vertical: true });
    expect(foldLayout(673, 841, folds).mode).toBe("book");
  });
});
