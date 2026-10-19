import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { itemKey } = await import("./collection");
const { DemoBackend } = await import("./libraryDemo");
const { lineKey } = await import("./trades");
const { UNSORTED_PLACE, pickPlace, printingChangeOps, repointTradeLine } = await import("./changePrinting");
type Item = import("./collection").Item;
type TradeLine = import("./trades").TradeLine;

/* Same cases as iOS ChangePrintingTests and Android ChangePrintingTest (contract/change-printing-2026-10-18.md). */

const item: Item = { k: itemKey("old", "nonfoil", "LP", "en"), cardId: "old", finish: "nonfoil", condition: "LP", lang: "en", qty: 4, seq: 1 };
const line = (card_id: string, finish: TradeLine["finish"], qty: number): TradeLine => ({ card_id, finish, condition: "NM", lang: "en", qty });

describe("change printing: owned copies", () => {
  it("moves copies in the same place", () => {
    const ops = printingChangeOps(item, "binder-1", "new", "foil", null, 2)!;
    expect(ops).toHaveLength(2);
    expect(itemKey(ops[0].card_id, ops[0].finish!, ops[0].condition!, ops[0].lang!)).toBe(item.k);
    expect(ops[0].delta).toBe(-2);
    expect(ops[0].binder_id).toBe("binder-1");
    expect(itemKey(ops[1].card_id, ops[1].finish!, ops[1].condition!, ops[1].lang!)).toBe(itemKey("new", "foil", "LP", "en"));
    expect(ops[1].delta).toBe(2);
    expect(ops[1].binder_id).toBe("binder-1");
  });

  it("sends no binder for Unsorted", () => {
    const ops = printingChangeOps(item, UNSORTED_PLACE, "new", "nonfoil", null, 1)!;
    expect("binder_id" in ops[0]).toBe(false);
    expect("binder_id" in ops[1]).toBe(false);
  });

  it("counts a finish alone as a change", () => {
    const ops = printingChangeOps(item, null, "old", "foil", null, 4)!;
    expect(itemKey(ops[1].card_id, ops[1].finish!, ops[1].condition!, ops[1].lang!)).toBe(itemKey("old", "foil", "LP", "en"));
  });

  it("follows a non-English printing's language, else keeps the copy's", () => {
    expect(printingChangeOps(item, null, "ja", "nonfoil", "ja", 1)![1].lang).toBe("ja");
    const jp: Item = { k: itemKey("old", "nonfoil", "NM", "ja"), cardId: "old", finish: "nonfoil", condition: "NM", lang: "ja", qty: 1, seq: 1 };
    expect(printingChangeOps(jp, null, "new", "nonfoil", "en", 1)![1].lang).toBe("ja");
  });

  it("sends nothing when there's nothing to change", () => {
    expect(printingChangeOps(item, null, "old", "nonfoil", null, 1)).toBeNull();
    expect(printingChangeOps(item, null, "new", "nonfoil", null, 0)).toBeNull();
    expect(printingChangeOps(item, null, "new", "nonfoil", null, 5)).toBeNull();
  });

  it("picks the chosen place, then the one opened from, then the one holding the most", () => {
    const places = [{ place: "a", qty: 1 }, { place: "b", qty: 3 }, { place: UNSORTED_PLACE, qty: 2 }];
    expect(pickPlace(places, "a", "b")).toBe("a");
    expect(pickPlace(places, null, UNSORTED_PLACE)).toBe(UNSORTED_PLACE);
    expect(pickPlace(places, "gone", "gone")).toBe("b");
    expect(pickPlace([], null, null)).toBeNull();
  });

  // Through the demo backend (same allocation rules as collection_apply): copies changed in a binder stay in it,
  // the other place keeps its copies, and Undo puts them back.
  it("keeps binder copies in the binder, and undoes", () => {
    const demo = new DemoBackend({
      summary: { total_qty: 3, unique_printings: 1, unique_cards: 1, value_usd: 0, value_eur: 0, seq: 0 },
      items: [["old", "nonfoil", "NM", "en", 3]], lists: [], prices: {},
    });
    demo.binders.clear();
    demo.allocs.clear();
    demo.saveBinder("box", "Box", false);
    const it = demo.items.get(itemKey("old", "nonfoil", "NM", "en"))!;
    // Box 2, Unsorted 1.
    demo.apply([{ card_id: "old", delta: -2 }, { card_id: "old", delta: 2, binder_id: "box" }], "binder");
    const res = demo.apply(printingChangeOps(it, "box", "new", "foil", null, 2)!, "manual");
    const newKey = itemKey("new", "foil", "NM", "en");
    expect(demo.items.get(it.k)?.qty).toBe(1);
    expect(demo.items.get(newKey)?.qty).toBe(2);
    expect(demo.allocs.get(`box|${newKey}`)?.qty).toBe(2);
    expect(demo.allocs.get(`box|${it.k}`)?.qty ?? 0).toBe(0);
    demo.undo(res.batch_id);
    expect(demo.items.get(it.k)?.qty).toBe(3);
    expect(demo.items.get(newKey)?.qty ?? 0).toBe(0);
    expect(demo.allocs.get(`box|${it.k}`)?.qty).toBe(2);
  });
});

describe("change printing: trade gets", () => {
  it("repoints a get", () => {
    const a = line("a", "nonfoil", 2), b = line("b", "nonfoil", 1);
    const out = repointTradeLine([a, b], lineKey(a), "c", "foil");
    expect(out.map((l) => l.card_id)).toEqual(["c", "b"]);
    expect(out[0].finish).toBe("foil");
    expect(out[0].qty).toBe(2);
  });

  it("merges into a get that already has that copy", () => {
    const a = line("a", "nonfoil", 2), b = line("b", "foil", 1);
    const out = repointTradeLine([a, b], lineKey(a), "b", "foil");
    expect(out).toHaveLength(1);
    expect(lineKey(out[0])).toBe(lineKey(b));
    expect(out[0].qty).toBe(3);
    expect(repointTradeLine([a, b], lineKey(a), "a", "nonfoil")).toEqual([a, b]);
  });
});
