import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { copiesOf, listAddOps, toCollectionOps, type AddMode } from "./listToCollection";
import type { Entry, ListKind } from "./lists";

/* Add a deck or cube to the collection against testdata/list-to-collection/cases.json (also iOS ListToCollectionTests
   and Android ListToCollectionTest). */

interface Case {
  name: string; kind: ListKind; mode: AddMode; sideboard?: boolean; only?: string[];
  entries: { card_id: string; board: Entry["board"]; finish: Entry["finish"]; qty: number }[];
  owned: Record<string, number>; ops: { card_id: string; finish: string; delta: number }[]; copies: number;
}
const { cases }: { cases: Case[] } = JSON.parse(readFileSync(new URL("../../../testdata/list-to-collection/cases.json", import.meta.url), "utf8"));

describe("listAddOps", () => {
  it("has cases", () => expect(cases.length).toBeGreaterThan(0));
  for (const c of cases) {
    it(c.name, () => {
      const entries: Entry[] = c.entries.map((e) => ({ cardId: e.card_id, board: e.board, qty: e.qty, finish: e.finish }));
      const ops = listAddOps(entries, c.kind, new Map(Object.entries(c.owned)), c.mode, c.sideboard ?? true, c.only ? new Set(c.only) : undefined);
      expect(ops).toEqual(c.ops);
      expect(copiesOf(ops)).toBe(c.copies);
    });
  }
});

describe("toCollectionOps", () => {
  it("uses the picked condition and the listed printing's language, never the one picked for adds", () => {
    const ops = toCollectionOps([{ card_id: "a", finish: "foil", delta: 2 }, { card_id: "j", finish: "nonfoil", delta: 1 }, { card_id: "u", finish: "nonfoil", delta: 1 }],
                                (id) => ({ a: "en", j: "ja" } as Record<string, string>)[id], "LP");
    expect(ops).toEqual([
      { card_id: "a", finish: "foil", condition: "LP", lang: "en", delta: 2 },
      { card_id: "j", finish: "nonfoil", condition: "LP", lang: "ja", delta: 1 },
      { card_id: "u", finish: "nonfoil", condition: "LP", lang: "en", delta: 1 },
    ]);
  });
});
