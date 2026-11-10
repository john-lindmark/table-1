import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  LIMITED_TOP, MANA_SYMBOLS, MIN_QUERY, OTHERS_MAX, limitedCards, limitedSearch, limitedValue, manaSymbols, overall, parseJoinCode,
} from "./limitedCards";
import type { Matchups } from "./insights";

const read = (f: string) => JSON.parse(readFileSync(new URL(`../../../testdata/${f}`, import.meta.url), "utf8"));
type Card = { n: string; r: string | null; col: string | null; gih: number | null; gih_n: number; oh: number | null; iwd: number | null; ata: number | null };

describe("the Limited page's cards (testdata/insights/limited-home.json)", () => {
  const f = read("insights/limited-home.json") as {
    top: number; others_max: number; min_query: number; avg: number; cards: Card[]; others: { key: string; cards: { n: string }[] }[];
    filters: { name: string; sort: string; rarity: string; color: string; unrated?: boolean; want: string[] }[];
    values: { card: string; sort: string; want: { value: string; vs: string | null } }[];
    search: { query: string; want: { here: string[]; elsewhere: [string, string][] } }[];
  };
  it("keeps the constants", () => {
    expect([LIMITED_TOP, OTHERS_MAX, MIN_QUERY]).toEqual([f.top, f.others_max, f.min_query]);
  });
  it("filters and sorts", () => {
    for (const c of f.filters) {
      const cards = c.unrated ? f.cards.slice(0, 12).map((x) => ({ ...x, r: null })) : f.cards;
      expect(limitedCards(cards, c.sort, c.rarity, c.color).map((x) => x.n), c.name).toEqual(c.want);
    }
  });
  it("words the values", () => {
    for (const v of f.values) expect(limitedValue(f.cards.find((c) => c.n === v.card)!, v.sort, f.avg), `${v.card} ${v.sort}`).toEqual(v.want);
  });
  it("searches the set, then the others", () => {
    const others = f.others.map((o) => ({ key: o.key, names: o.cards.map((c) => c.n) }));
    for (const s of f.search) expect(limitedSearch(s.query, f.cards.map((c) => c.n), others), s.query).toEqual(s.want);
  });
});

describe("the grid's Overall column (testdata/insights/overall.json)", () => {
  const f = read("insights/overall.json") as { share: { a: number; rec: [number, number, number] | null }[]; matchups: Matchups; cases: { a: number; want: unknown }[] };
  it("reads the record, else sums the row", () => {
    for (const c of f.cases) expect(overall(f.share, f.matchups, c.a), String(c.a)).toEqual(c.want);
  });
});

describe("mana symbols (testdata/mana-symbols/cases.json)", () => {
  const f = read("mana-symbols/cases.json") as { symbols: string[]; cases: { cost: string; want: string[] }[] };
  it("parses costs", () => { for (const c of f.cases) expect(manaSymbols(c.cost), c.cost).toEqual(c.want); });
  it("bundles every symbol", () => {
    expect([...MANA_SYMBOLS].sort()).toEqual([...f.symbols].sort());
    for (const s of f.symbols) expect(() => readFileSync(new URL(`../../public/mana/${s}.svg`, import.meta.url))).not.toThrow();
  });
});

describe("pasted event codes (testdata/join-code/cases.json)", () => {
  const f = read("join-code/cases.json") as { cases: { text: string; want: unknown }[] };
  it("reads the code", () => { for (const c of f.cases) expect(parseJoinCode(c.text), c.text).toEqual(c.want); });
});
