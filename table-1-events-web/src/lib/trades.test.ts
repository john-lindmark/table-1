// Bug #5: deleting a trade from its editor also goes back to the list, which reloads. That read could start before
// the delete committed and bring the deleted trade back; opening it and editing then failed ("That trade is gone or
// already confirmed"). The store keeps trades deleted this session out of every read. Same cases as iOS
// TradesStoreTests.swift and Android TradesStoreTest.kt.
import { describe, expect, it } from "vitest";
import { applyLoadedTrades, forgetTrade, saveTrade, tradesState, type Trade } from "./trades";

const trade = (id: string): Trade => ({
  id, partner: null, note: null, status: "draft", gives: [], gets: [], batch_id: null,
  created_at: "", updated_at: "", confirmed_at: null,
});

describe("deleted trades stay deleted", () => {
  it("a list read from before a delete keeps it gone", () => {
    applyLoadedTrades([trade("a"), trade("b")]);
    forgetTrade("a");
    expect(tradesState().trades.map((t) => t.id)).toEqual(["b"]);
    applyLoadedTrades([trade("a"), trade("b")]);
    expect(tradesState().trades.map((t) => t.id)).toEqual(["b"]);
  });

  it("a save of a deleted trade is dropped", async () => {
    applyLoadedTrades([trade("c")]);
    forgetTrade("c");
    const t = await saveTrade(trade("c"), "Sam", [], []);
    expect(t.id).toBe("c");
    expect(tradesState().trades).toEqual([]);
  });
});
