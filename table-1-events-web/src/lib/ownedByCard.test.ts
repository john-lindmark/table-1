import { describe, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { autoMatch, cardOfMap, holdings, matchOps, missingByCard, shorts, tapPick, type Need } from "./ownedByCard";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { listAddOps } = await import("./listToCollection");
type Entry = import("./lists").Entry;

/* Owning a card in any printing and Match collection (contract/owned-by-card-2026-10-31.md) against
   testdata/owned-by-card/cases.json, shared with iOS and Android. */

interface L { card_id: string; board: string; finish: string; qty: number; lang?: string }
const cases = JSON.parse(readFileSync(new URL("../../../testdata/owned-by-card/cases.json", import.meta.url), "utf8"));
const need = (l: L): Need => ({ cardId: l.card_id, board: l.board, finish: l.finish, qty: l.qty, lang: l.lang ?? "en" });
const entry = (l: L) => ({ cardId: l.card_id, board: l.board, qty: l.qty, finish: l.finish, ...(l.lang ? { lang: l.lang } : {}) }) as unknown as Entry;
const owned = (o: Record<string, number>) => new Map(Object.entries(o));
const basics = new Set<string>(cases.basics);

describe("owned by card", () => {
  for (const c of cases.shorts) {
    it(`shorts: ${c.name}`, () => {
      expect(shorts(c.lines.map(need), holdings(owned(c.owned), cardOfMap(c.oracles)), basics)).toEqual(c.shorts);
    });
  }
  it("Wants → Missing, one line per card", () => {
    const l = cases.lines;
    const got = missingByCard(l.lists.map((x: { name: string; event?: boolean; entries: L[] }) => ({ name: x.name, event: !!x.event, lines: x.entries.map(need) })),
                              holdings(owned(l.owned), cardOfMap(l.oracles)), basics);
    expect(got.map((m) => ({ card_id: m.cardId, finish: m.finish, short: m.short, lists: m.lists }))).toEqual(l.expect);
  });
  for (const c of cases.add) {
    it(`add to collection: ${c.name}`, () => {
      expect(listAddOps(c.entries.map(entry), c.kind, owned(c.owned), c.mode, true, undefined, undefined, cardOfMap(c.oracles))).toEqual(c.ops);
    });
  }
  for (const c of cases.match) {
    it(`match collection: ${c.name}`, () => {
      const lines = c.lines.map(need);
      const versions = c.versions.map((v: { card_id: string; finish: string; owned: number }) => ({ cardId: v.card_id, finish: v.finish, owned: v.owned }));
      const pick = (p: { card_id: string; finish: string; qty: number }) => ({ cardId: p.card_id, finish: p.finish, qty: p.qty });
      let picks = autoMatch(lines, versions);
      expect(picks).toEqual(c.auto.map(pick));
      const total = lines.reduce((n: number, l: Need) => n + l.qty, 0);
      for (const [card, finish] of c.taps) picks = tapPick(picks, versions, total, card, finish);
      expect(picks).toEqual(c.picks.map(pick));
      expect(matchOps(lines, picks)).toEqual(c.ops.map((o: { card_id: string; finish: string; lang?: string; to_card_id: string; to_finish: string; qty: number }) =>
        ({ cardId: o.card_id, finish: o.finish, ...(o.lang ? { lang: o.lang } : {}), toCardId: o.to_card_id, toFinish: o.to_finish, qty: o.qty })));
    });
  }
});
