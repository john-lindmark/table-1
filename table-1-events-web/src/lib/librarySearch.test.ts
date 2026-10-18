import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import type { Binder, Want } from "./binders";
import type { Item } from "./collection";
import { cardMatches, matchingLines, moveInSource, printingMatches, repointWant } from "./librarySearch";

/* Same cases as iOS LibrarySearchTests and Android LibrarySearchTest. */

const cases = JSON.parse(readFileSync(new URL("../../../testdata/library-search/cases.json", import.meta.url), "utf8")) as {
  cards: { query: string; name: string; type: string; match: boolean }[];
  printings: { query: string; set: string; cn: string; releasedAt: string; match: boolean }[];
};

describe("library search", () => {
  it("matches the shared card cases", () => {
    for (const c of cases.cards) expect(cardMatches(c.query, c.name, c.type), `${c.query} / ${c.name}`).toBe(c.match);
  });
  it("matches the shared printing cases", () => {
    for (const c of cases.printings) expect(printingMatches(c.query, c.set, c.cn, c.releasedAt), `${c.query} / ${c.set} ${c.cn}`).toBe(c.match);
  });
  it("remove search only offers the list's own cards", () => {
    const lines = [
      { name: "Lightning Bolt", type: "Instant", board: "main", finish: "nonfoil" },
      { name: "Lightning Helix", type: "Instant", board: "maybe", finish: "nonfoil" },
      { name: "Counterspell", type: "Instant", board: "main", finish: "nonfoil" },
    ];
    expect(matchingLines(lines, "light").map((l) => l.name)).toEqual(["Lightning Bolt", "Lightning Helix"]);
    expect(matchingLines(lines, "")).toEqual([]);
    expect(matchingLines(lines, "lightning strike")).toEqual([]);
  });
});

describe("want printings", () => {
  it("moves the count and max price to the new printing", () => {
    const w: Want = { oracleId: "o", cardId: null, finish: null, qty: 3, maxUsd: 5, seq: 1 };
    expect(repointWant(w, "p", "foil")).toEqual([
      { oracle_id: "o", card_id: null, finish: null, qty: 0 },
      { oracle_id: "o", card_id: "p", finish: "foil", delta: 3, max_usd: 5 },
    ]);
    expect(repointWant(w, null, "foil")).toBeNull();
    const back = repointWant({ oracleId: "o", cardId: "p", finish: "foil", qty: 1, maxUsd: null, seq: 2 }, null, "foil")!;
    expect(back[1]).toEqual({ oracle_id: "o", card_id: null, finish: null, delta: 1, max_usd: null });
  });
});

describe("binder move in", () => {
  const trade: Binder = { id: "t", name: "A trade", for_trade: true, seq: 1 };
  const box: Binder = { id: "b", name: "Box", for_trade: false, seq: 2 };
  const item = (cardId: string, finish: Item["finish"], qty: number): Item =>
    ({ k: `${cardId}|${finish}|NM|en`, cardId, finish, condition: "NM", lang: "en", qty, seq: 1 });
  const a = item("c1", "nonfoil", 4), b = item("c2", "foil", 1);
  it("takes Unsorted, then binders not for trade, then for-trade binders", () => {
    expect(moveInSource([{ item: a, from: trade, qty: 2 }, { item: a, from: box, qty: 1 }, { item: b, from: null, qty: 1 }], "x")?.item.cardId).toBe("c2");
    expect(moveInSource([{ item: a, from: trade, qty: 2 }, { item: a, from: box, qty: 1 }], "x")?.from).toBe("b");
    expect(moveInSource([{ item: a, from: trade, qty: 2 }, { item: a, from: box, qty: 1 }], "b")?.from).toBe("t");
    expect(moveInSource([{ item: a, from: box, qty: 1 }], "b")).toBeNull();
  });
});
