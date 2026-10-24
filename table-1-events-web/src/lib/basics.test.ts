import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { basicCardIds, parsePack } = await import("./catalog");
const { missingLines } = await import("./binders");
const { missingIn } = await import("./lists");
const { listAddOps } = await import("./listToCollection");
type CardList = import("./lists").CardList;
type Entry = import("./lists").Entry;
type AddMode = import("./listToCollection").AddMode;

/* Basic lands are never missing (contract/basics-2026-10-24.md) against testdata/basics/cases.json (also iOS
   BasicsTests and Android BasicsTest), and the catalog's set of basic printings. */

interface Cases {
  basics: string[];
  lists: { name: string; kind: CardList["kind"]; entries: { card_id: string; board: Entry["board"]; finish: Entry["finish"]; qty: number }[] }[];
  owned: Record<string, number>;
  missing: Record<string, number>;
  missingWithoutBasics: Record<string, number>;
  lines: { card_id: string; finish: string; short: number; lists: string[] }[];
  add: { list: string; mode: AddMode; ops: { card_id: string; finish: string; delta: number }[] }[];
}
const c: Cases = JSON.parse(readFileSync(new URL("../../../testdata/basics/cases.json", import.meta.url), "utf8"));

describe("basics", () => {
  const basics = new Set(c.basics);
  const owned = new Map(Object.entries(c.owned));
  const lists: CardList[] = c.lists.map((l) => ({
    id: l.name, kind: l.kind, name: l.name, format: "modern",
    versions: [{ number: 1, at: 0, note: "", entries: l.entries.map((e) => ({ cardId: e.card_id, board: e.board, qty: e.qty, finish: e.finish })) }],
  }));

  it("never count as missing from a list", () => {
    for (const l of lists) {
      expect(missingIn(l, owned, basics)).toBe(c.missing[l.name]);
      expect(missingIn(l, owned, new Set())).toBe(c.missingWithoutBasics[l.name]);
    }
  });

  it("stay out of Wants → Missing", () => {
    expect(missingLines(lists, owned, basics).map((m) => ({ card_id: m.cardId, finish: m.finish, short: m.short, lists: m.lists }))).toEqual(c.lines);
  });

  it("only Every card adds them to the collection", () => {
    for (const a of c.add) {
      const l = lists.find((x) => x.name === a.list)!;
      expect(listAddOps(l.versions[0].entries, l.kind, owned, a.mode, true, undefined, basics)).toEqual(a.ops);
    }
  });

  it("are the printings of cards with the Basic supertype", () => {
    const pack = [
      "#t1catalog\t1\tv1-test\t4\t5",
      "O\t0\t11111111-1111-1111-1111-111111111111\tIsland\tisland\tBasic Land — Island\t\t0\t\t\tLLLLLLLL",
      "O\t1\t22222222-2222-2222-2222-222222222222\tSnow-Covered Forest\tsnow covered forest\tBasic Snow Land — Forest\t\t0\t\t\tLLLLLLLL",
      "O\t2\t33333333-3333-3333-3333-333333333333\tVolcanic Island\tvolcanic island\tLand — Island Mountain\t\t0\t\t\t---LL-L-",
      "O\t3\t44444444-4444-4444-4444-444444444444\tScrying Sheets\tscrying sheets\tSnow Land\t\t0\t\t\t--LLLLL-",
      "P\ta\t0\tlea\t287\ten\tc\tn\t1993-08-05\t\t1\t",
      "P\tb\t0\tdmu\t264\ten\tc\tfn\t2022-09-09\t\t1\t",
      "P\tc\t1\tkhm\t285\ten\tc\tfn\t2021-02-05\t\t1\t",
      "P\td\t2\tlea\t283\ten\tr\tn\t1993-08-05\t\t1\t",
      "P\te\t3\tcsp\t157\ten\tu\tfn\t2006-07-21\t\t1\t",
    ].join("\n");
    expect([...basicCardIds(parsePack("v1-test", pack))].sort()).toEqual(["a", "b", "c"]);
    expect(basicCardIds(null).size).toBe(0);
  });
});
