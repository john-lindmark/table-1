import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { applySort, sortKey, sortOf, sortOptions, type CardSort, type SortScreen } from "./cardSort";

/* Sort (contract/card-sort-2026-10-25.md) against the shared cases in testdata/card-sort/cases.json, the same file
   iOS CardSortTests and Android CardSortTest read. */

interface Cases {
  cards: { name: string; cmc: number; land: boolean; released: string; set: string; cn: string }[];
  order: Record<string, string[]>;
  options: Record<string, string[]>;
  defaults: Record<string, string>;
}
const cases: Cases = JSON.parse(readFileSync(new URL("../../../testdata/card-sort/cases.json", import.meta.url), "utf8"));

describe("orders", () => {
  for (const s of ["name", "manaValue", "set"] as CardSort[]) {
    it(s, () => {
      const got = applySort(cases.cards, s, (c) => sortKey(c.name, c.cmc, c.land, c.released, c.set, c.cn));
      expect(got.map((c) => c.name)).toEqual(cases.order[s]);
    });
  }
  it("leaves the screen's own orders alone", () => {
    expect(applySort(["b", "a"], "count", (x) => sortKey(x))).toEqual(["b", "a"]);
    expect(applySort(["b", "a"], "name", (x) => sortKey(x))).toEqual(["a", "b"]);
  });
});

describe("options and defaults", () => {
  const screens: [string, SortScreen][] = [["deck", "list"], ["cube", "list"], ["shared", "shared"], ["binder", "binder"], ["allCards", "allCards"]];
  for (const [name, s] of screens) {
    it(name, () => {
      expect(sortOptions(s)).toEqual(cases.options[name]);
      expect(sortOf(null, s)).toBe(cases.defaults[name]);
    });
  }
  it("falls back from another screen's sort", () => {
    expect(sortOf("recent", "list")).toBe("name");
    expect(sortOf("set", "binder")).toBe("set");
  });
});
