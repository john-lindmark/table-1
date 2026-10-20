import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { groupKeys, groupLabel, groupSections, groupingOptions, groupingOrder, sortGroups, type Grouping } from "./cardGrouping";

/* Group by (contract/shared-lists-grouping-2026-10-20.md §4) against the shared cases in
   testdata/card-grouping/cases.json, the same file iOS CardGroupingTests and Android CardGroupingTest read. */

interface Cases {
  cards: { name: string; typeLine: string; manaCost: string; colors: string; cmc: number; type: string; color: string; manaValue: string }[];
  order: Record<string, string[]>;
}
const cases: Cases = JSON.parse(readFileSync(new URL("../../../testdata/card-grouping/cases.json", import.meta.url), "utf8"));

describe("groupKeys", () => {
  it("has the shared cases", () => expect(cases.cards.length).toBeGreaterThanOrEqual(10));
  for (const c of cases.cards) {
    it(c.name, () => {
      expect(groupKeys(c.typeLine, c.manaCost, c.colors, c.cmc)).toEqual({ type: c.type, color: c.color, manaValue: c.manaValue });
    });
  }
});

describe("order", () => {
  for (const g of ["type", "color", "manaValue"] as Grouping[]) {
    it(g, () => {
      const order = cases.order[g];
      expect(groupingOrder(g)).toEqual(order);
      expect(sortGroups(g, order.slice().reverse())).toEqual(order);
    });
  }
  it("puts unknown keys last, by name", () => expect(sortGroups("type", ["Zed", "Lands", "Abc"])).toEqual(["Lands", "Abc", "Zed"]));
});

describe("labels and options", () => {
  it("reads mana values as headings", () => {
    expect(groupLabel("manaValue", "3")).toBe("Mana value 3");
    expect(groupLabel("manaValue", "Lands")).toBe("Lands");
    expect(groupLabel("type", "Creatures")).toBe("Creatures");
  });
  it("offers None only off lists", () => {
    expect(groupingOptions(true)).toEqual(["type", "color", "manaValue"]);
    expect(groupingOptions(false)).toEqual(["none", "type", "color", "manaValue"]);
  });
});

describe("groupSections", () => {
  const k = (t: string) => groupKeys(t, "", "", 0);
  it("keeps the screen's order inside a group", () => {
    const items = ["Sorcery", "Creature", "Basic Land", "Creature — Elf"];
    expect(groupSections(items, "type", k)).toEqual([
      { key: "Creatures", items: ["Creature", "Creature — Elf"] }, { key: "Sorceries", items: ["Sorcery"] }, { key: "Lands", items: ["Basic Land"] },
    ]);
  });
  it("is one untitled section for None", () => expect(groupSections([1, 2], "none", () => k(""))).toEqual([{ key: "", items: [1, 2] }]));
});
