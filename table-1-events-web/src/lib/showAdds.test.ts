import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { shiftAdds } = await import("./collection");
const { shiftAllocs } = await import("./binders");
type Item = import("./collection").Item;
type Alloc = import("./binders").Alloc;
type CollectionOp = import("./collection").CollectionOp;

/* Added copies show before the server answers and are taken back if the call fails. Shared cases
   testdata/show-adds/cases.json (also iOS ShowAddsTests and Android ShowAddsTest). */

interface Case {
  name: string;
  items: Record<string, number>;
  allocs: Record<string, number>;
  ops: CollectionOp[];
  shown: { items: Record<string, number>; allocs: Record<string, number> };
}
const c: { cases: Case[] } = JSON.parse(readFileSync(new URL("../../../testdata/show-adds/cases.json", import.meta.url), "utf8"));

const qtys = <T extends { qty: number }>(m: Map<string, T>) => Object.fromEntries([...m].map(([k, v]) => [k, v.qty]));

describe("show adds", () => {
  for (const k of c.cases) {
    it(k.name, () => {
      let items = new Map<string, Item>(Object.entries(k.items).map(([key, qty]) => {
        const [cardId, finish, condition, lang] = key.split("|") as [string, Item["finish"], Item["condition"], string];
        return [key, { k: key, cardId, finish, condition, lang, qty, seq: 7 }];
      }));
      let allocs = new Map<string, Alloc>(Object.entries(k.allocs).map(([key, qty]) => {
        const [binderId, cardId, finish, condition, lang] = key.split("|") as [string, string, Item["finish"], Item["condition"], string];
        return [key, { binderId, cardId, finish, condition, lang, qty, seq: 3 }];
      }));

      let r = shiftAdds(items, k.ops, 1);
      items = r.items;
      allocs = shiftAllocs(allocs, r.allocs);
      expect(qtys(items)).toEqual(k.shown.items);
      expect(qtys(allocs)).toEqual(k.shown.allocs);
      // A held item keeps its seq, so the sync row that follows is never skipped as older.
      for (const key of Object.keys(k.items)) expect(items.get(key)?.seq).toBe(7);

      r = shiftAdds(items, k.ops, -1);
      expect(qtys(r.items)).toEqual(k.items);
      expect(qtys(shiftAllocs(allocs, r.allocs))).toEqual(k.allocs);
    });
  }
});
