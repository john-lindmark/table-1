import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { groupKeys } from "./cardGrouping";
import { ASPECT, HEADER, ROW_GAP, columns, fileName, fit, mainCount, ordered, plan, type PlanLine } from "./deckImage";

/* Deck image layout (contract/deck-image-2026-10-20.md), the same checks as iOS DeckImageTests; card sizes against
   testdata/deck-image/cases.json (also read by iOS and Android). */

const cases: { fit: { main: number; side: number; cols: number; cw: number; step: number; height: number }[] } =
  JSON.parse(readFileSync(new URL("../../../testdata/deck-image/cases.json", import.meta.url), "utf8"));

const line = (name: string, board: string, qty: number, type: string, mv: number, card = name): PlanLine =>
  ({ cardId: card, oracleId: name, name, board, qty, p: null, set: "", finish: "nonfoil", keys: groupKeys(type, "", "R", mv) });

describe("plan", () => {
  const lines = [
    line("Mountain", "main", 10, "Basic Land — Mountain", 0),
    line("Lightning Bolt", "main", 2, "Instant", 1, "bolt-a"),
    line("Lightning Bolt", "main", 2, "Instant", 1, "bolt-b"),
    line("Goblin Guide", "main", 4, "Creature — Goblin", 1),
    line("Fury", "main", 1, "Creature — Elemental", 5),
    line("Atraxa", "commander", 1, "Legendary Creature — Phyrexian", 7),
    line("Blood Moon", "side", 3, "Enchantment", 3),
    line("Maybe card", "maybe", 1, "Sorcery", 2),
  ];
  it("orders, merges and leaves out Considering", () => {
    const p = plan(lines, "type");
    expect(p.main.map((x) => x.title)).toEqual(["Commander", "Creatures", "Instants", "Lands"]);
    expect(p.main[1].cards.map((c) => c.name)).toEqual(["Goblin Guide", "Fury"]);
    expect(p.main[2].cards.map((c) => c.qty)).toEqual([4]);
    expect(mainCount(p)).toBe(20); // the commander counts toward the deck
    expect(p.side.map((c) => c.name)).toEqual(["Blood Moon"]);
    expect(ordered(p).some((c) => c.name === "Maybe card")).toBe(false);
  });
  it("groups by mana value", () => {
    expect(plan(lines, "manaValue").main.map((x) => x.title)).toEqual(["Commander", "Mana value 1", "Mana value 5", "Lands"]);
  });
  it("None groups by type", () => {
    expect(plan(lines, "none").main.map((x) => x.title)).toEqual(["Commander", "Creatures", "Instants", "Lands"]);
  });
});

describe("fit", () => {
  for (const c of cases.fit) {
    it(`${c.main} + ${c.side}`, () => {
      const f = fit(c.main, c.side);
      expect({ cols: f.cols, cw: f.cw, height: f.height }).toEqual({ cols: c.cols, cw: c.cw, height: c.height });
      expect(f.step).toBeCloseTo(c.step, 3);
      const rows = Math.ceil(c.main / f.cols);
      expect(HEADER + rows * f.cw * ASPECT + (rows - 1) * ROW_GAP).toBeLessThanOrEqual(f.height);
    });
  }
});

describe("columns and file name", () => {
  it("splits tall groups", () => {
    const cards = Array.from({ length: 12 }, (_, i) => ({ key: `${i}`, name: `L${i}`, qty: 1, p: null, set: "", finish: "nonfoil" }));
    const cols = columns([{ title: "Lands", cards }], 9);
    expect(cols.map((c) => c.cards.length)).toEqual([9, 3]);
    expect(cols.map((c) => c.title)).toEqual(["Lands · 12", null]);
  });
  it("names the file for the deck", () => expect(fileName("Izzet: Tempo!")).toBe("Izzet Tempo.jpg"));
});
