import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { buyCalls, buyRows, buyTotals, mergeAnswers, type BuyLine } from "./buyList";
import { cardOfMap, holdings } from "./ownedByCard";

/* The Buy screen (contract/buy-2026-11-06.md) against testdata/buy/cases.json, which iOS and Android read too. */

const cases = JSON.parse(readFileSync(new URL("../../../testdata/buy/cases.json", import.meta.url), "utf8"));

describe("buy", () => {
  it("works out rows, totals and calls", () => {
    for (const c of cases.cases) {
      const lines: BuyLine[] = c.lines.map((l: Record<string, unknown>) => ({
        cardId: l.card_id, oracleId: l.oracle_id, any: l.any, board: l.board, finish: l.finish, qty: l.qty, unit: l.unit, basic: l.basic,
      }));
      const o = c.options;
      const rows = buyRows(lines, holdings(new Map(Object.entries(c.owned)), cardOfMap(cases.oracles)),
                           { skipOwned: o.skip_owned, anyPrinting: o.any_printing, exact: o.exact, boards: new Set(o.boards) });
      expect(rows.map((r) => ({ card_id: r.line.cardId, board: r.line.board, finish: r.line.finish, qty: r.line.qty, owned: r.owned, buy: r.buy })), c.name)
        .toEqual(c.rows);
      const t = buyTotals(rows);
      expect({ cards: t.cards, owned: t.owned, buy: t.buy, price: t.price, owned_value: t.ownedValue, total: t.total, unpriced: t.unpriced }, c.name)
        .toEqual(c.totals);
      expect(buyCalls(rows, o.exact), c.name).toEqual(c.calls);
    }
  });

  it("merges two answers", () => {
    for (const m of cases.merge) expect(mergeAnswers(m.answers), m.name).toEqual(m.merged);
  });
});
