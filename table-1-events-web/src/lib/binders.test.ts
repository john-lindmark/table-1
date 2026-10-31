import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { parsePack } = await import("./catalog");
const { meetWants, missingLines, planAllocations, wantFor, wantKey } = await import("./binders");
const { ImportResolver, exportCsv, importItems, importPlacements, importWants, parseCsv } = await import("./collectionCsv");
type Binder = import("./binders").Binder;
type Want = import("./binders").Want;
type CardList = import("./lists").CardList;
type ExportCard = import("./collectionCsv").ExportCard;

/* Binders, "for trade" and wants on the web (contract/binders-wants-2026-10-17.md): the allocation rules the dev demo
   applies (the server's are tested in supabase/tests/70_binders_wants_test.sql), the Missing view, which want a
   trade's get meets, and the CSV binder and tradelist columns. Same cases as apps/ios/Table1Tests/BindersTests.swift. */

const root = new URL("../../../testdata/", import.meta.url);
const fixture = (name: string) => readFileSync(new URL(`collection-import/${name}`, root), "utf8");
const setNames = JSON.parse(fixture("sets.json")) as { code: string; name: string }[];
const catalog = parsePack("test", gunzipSync(readFileSync(new URL("scan/catalog.tsv.gz", root))).toString("utf8"));

const binders = new Map<string, Binder>([
  ["t", { id: "t", name: "Trade binder", for_trade: true, seq: 1 }],
  ["a", { id: "a", name: "Alpha", for_trade: false, seq: 2 }],
  ["b", { id: "b", name: "Box 3", for_trade: false, seq: 3 }],
]);
const plan = (cur: Record<string, number>, hints: Record<string, number>, qty: number) =>
  Object.fromEntries(planAllocations(new Map(Object.entries(cur)), new Map(Object.entries(hints)), qty, binders));

describe("allocation rules", () => {
  it("takes Unsorted copies first", () => {
    expect(plan({ a: 1, b: 2, t: 2 }, {}, 5)).toEqual({ a: 1, b: 2, t: 2 });
  });
  it("then binders not for trade by name, then for-trade binders", () => {
    expect(plan({ a: 1, b: 2, t: 2 }, {}, 2)).toEqual({ a: 0, b: 0, t: 2 });
    expect(plan({ a: 1, b: 2, t: 2 }, {}, 1)).toEqual({ a: 0, b: 0, t: 1 });
  });
  it("gives from a named binder first and adds into one", () => {
    expect(plan({ b: 2, t: 1 }, { t: -1 }, 2)).toEqual({ b: 2, t: 0 });
    expect(plan({ b: 2 }, { b: 2 }, 6)).toEqual({ b: 4 });
    expect(plan({}, { gone: 3 }, 3)).toEqual({});
  });
});

describe("wants", () => {
  it("meets the exact printing and finish, then the printing, then any printing", () => {
    const wants = new Map<string, Want>();
    for (const w of [
      { oracleId: "o", cardId: null, finish: null, qty: 2, maxUsd: null, seq: 1 },
      { oracleId: "o", cardId: "p", finish: null, qty: 1, maxUsd: null, seq: 2 },
      { oracleId: "o", cardId: "p", finish: "foil", qty: 1, maxUsd: null, seq: 3 },
    ] as Want[]) wants.set(wantKey(w.oracleId, w.cardId, w.finish), w);
    expect(wantFor("o", "p", "foil", [...wants.values()])?.finish).toBe("foil");
    expect(wantFor("o", "p", "nonfoil", [...wants.values()])?.cardId).toBe("p");
    expect(wantFor("o", "q", "nonfoil", [...wants.values()])?.cardId).toBeNull();
    expect(wantFor("x", "q", "nonfoil", [...wants.values()])).toBeUndefined();
    expect(meetWants("o", "p", "foil", 3, wants)).toHaveLength(3);
    expect(wants.get(wantKey("o", "p", "foil"))?.qty).toBe(0);
    expect(wants.get(wantKey("o", "p", null))?.qty).toBe(0);
    expect(wants.get(wantKey("o", null, null))?.qty).toBe(1);
  });

  it("Missing takes the largest need per card across lists, skipping Considering and roto decks", () => {
    const list = (id: string, entries: CardList["versions"][0]["entries"], eventId?: string): CardList =>
      ({ id, kind: "deck", name: `Deck ${id}`, format: "modern", versions: [{ number: 1, at: 0, note: "", entries }], eventId });
    const lists = [
      list("1", [{ cardId: "bolt", board: "main", qty: 4 }, { cardId: "opt", board: "maybe", qty: 4 }]),
      list("2", [{ cardId: "bolt", board: "main", qty: 2 }, { cardId: "bolt", board: "side", qty: 1 },
                 { cardId: "bolt", board: "main", qty: 2, finish: "foil" }]),
      list("3", [{ cardId: "shock", board: "main", qty: 4 }], "roto"),
    ];
    const lines = missingLines(lists, new Map([["bolt|nonfoil", 1]]), new Set());
    expect(lines.map((m) => `${m.cardId}|${m.finish} ${m.short} ${m.lists.join("+")}`)).toEqual(["bolt|nonfoil 4 Deck 1+Deck 2"]); // one line per card: any finish covers it
    expect(missingLines(lists, new Map([["bolt|nonfoil", 4], ["bolt|foil", 1]]), new Set())).toEqual([]);
  });
});

describe("CSV binders and tradelists", () => {
  const resolve = (text: string) => new ImportResolver(catalog, setNames).resolveAll(parseCsv(text).rows).matched;

  it("reads ManaBox binders, lists and decks", () => {
    const p = parseCsv(fixture("manabox.csv"));
    expect(p.rows[0].binder).toBe("My collection");
    expect(p.rows.filter((r) => r.binder === "Trade binder")).toHaveLength(16);
    const text = "Binder Name,Binder Type,Name,Set code,Collector number,Foil,Quantity\n"
      + "Box 3,binder,Lightning Bolt,M11,149,normal,4\nWishlist,list,Lightning Bolt,M11,149,foil,2\nBurn,deck,Lightning Bolt,M11,149,normal,1\n";
    const rows = parseCsv(text).rows;
    expect(rows.map((r) => r.binder)).toEqual(["Box 3", null, null]);
    expect(rows.map((r) => r.wanted)).toEqual([false, true, false]);
    const m = resolve(text);
    expect(importItems(catalog, m).reduce((n, it) => n + it.qty, 0)).toBe(5);
    expect(importPlacements(catalog, m).map((p) => `${p.binder} ${p.qty}`)).toEqual(["Box 3 4"]);
    expect(importWants(catalog, m).map((w) => `${w.finish} ${w.qty}`)).toEqual(["foil 2"]);
  });

  it("reads tradelist counts and Dragon Shield folders", () => {
    const deckbox = "Count,Tradelist Count,Name,Edition,Edition Code,Card Number\n4,3,Lightning Bolt,Magic 2011,m11,149\n2,9,Opt,Ixalan,xln,65\n1,,Shock,M19,m19,156\n";
    expect(parseCsv(deckbox).rows.map((r) => r.tradeQty)).toEqual([3, 2, 0]);
    const mox = '"Count","Tradelist Count","Name","Edition","Collector Number"\n"4","1","Lightning Bolt","m11","149"\n';
    expect(parseCsv(mox).rows[0].tradeQty).toBe(1);
    const ds = '"sep=,"\nFolder Name,Quantity,Trade Quantity,Card Name,Set Code,Card Number\nBox,4,1,Lightning Bolt,M11,149\n';
    expect(parseCsv(ds).rows[0]).toMatchObject({ binder: "Box", tradeQty: 1 });
    expect(new Set(importPlacements(catalog, resolve(ds)).map((p) => `${p.binder} ${p.qty}`))).toEqual(new Set(["Trade binder 1", "Box 3"]));
  });

  it("exports binders and reads them back", () => {
    const card = (qty: number, binder: string | null, forTrade = false, wanted = false): ExportCard => ({
      name: "Lightning Bolt", set: "m11", setName: "Magic 2011", cn: "149", rarity: "c", cardId: "bolt", finish: "nonfoil",
      condition: "NM", lang: "en", qty, binder, forTrade, wanted,
    });
    const cards = [card(2, "Trade binder", true), card(1, "Box 3"), card(1, null), card(3, null, false, true)];
    const manabox = parseCsv(exportCsv(cards, "manabox")).rows;
    expect(manabox.filter((r) => !r.wanted).map((r) => `${r.binder ?? "-"} ${r.qty}`).sort()).toEqual(["- 1", "Box 3 1", "Trade binder 2"]);
    expect(manabox.filter((r) => r.wanted).map((r) => r.qty)).toEqual([3]);
    const mox = parseCsv(exportCsv(cards, "moxfield")).rows;
    expect(mox.map((r) => `${r.qty}/${r.tradeQty}`)).toEqual(["4/2"]);
  });
});
