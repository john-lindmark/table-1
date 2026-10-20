import { readFileSync } from "node:fs";
import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
vi.mock("./telemetry", () => ({ capture: vi.fn(), reportError: vi.fn() }));
const { normName, parsePack } = await import("./catalog");
const { EMPTY_ADVANCED, advancedQuery, hasSyntax, isLocal, localSearch, matches, parseQuery, runCardSearch, usesPrinting } = await import("./cardQuery");
const { COLLAPSED, isOpen, lineGroups, oldestFirst, priceRank, setAll, toggleOne } = await import("./printings");
const { HERO_LIMIT, heroPrintings, scopeKey, scopeOf, toggledList } = await import("./heroes");

/* Advanced search and the Library polish rules (contract/library-polish-2026-10-19.md). Queries and form fields come
   from testdata/card-query/cases.json, shared with iOS (Table1Tests/CardQueryTests.swift) and Android. */

interface Printing { set: string; cn: string; rarity: string; released: string; lang: string; finishes: string }
interface Card { name: string; type: string; cost: string; cmc: number; colors: string; legal: string; produced: string; printings: Printing[] }
interface Cases {
  cards: Card[];
  queries: { q: string; syntax: boolean; local?: boolean; names?: string[] }[];
  advanced: { fields: Record<string, string>; query: string }[];
}

const cases = JSON.parse(readFileSync(new URL("../../../testdata/card-query/cases.json", import.meta.url), "utf8")) as Cases;

/** The cases' cards as a pack (format 1), one O line per card and its P lines in order. */
function catalog() {
  const nP = cases.cards.reduce((n, c) => n + c.printings.length, 0);
  const lines = [`#t1catalog\t1\tcases\t${cases.cards.length}\t${nP}`];
  cases.cards.forEach((c, i) => {
    lines.push(["O", i, `00000000-0000-0000-0000-${String(i).padStart(12, "0")}`, c.name, normName(c.name), c.type, c.cost, c.cmc, c.colors,
                c.name, c.legal, 0, c.produced, ""].join("\t"));
  });
  cases.cards.forEach((c, i) => c.printings.forEach((p, j) => {
    lines.push(["P", `p${i}-${j}`, i, p.set, p.cn, p.lang, p.rarity, p.finishes, p.released, "", 1, "", j === 0 ? "1" : ""].join("\t"));
  }));
  return parsePack("cases", lines.join("\n"));
}

describe("Scryfall syntax (shared cases)", () => {
  const c = catalog();
  for (const q of cases.queries) {
    it(q.q, () => {
      expect(hasSyntax(q.q)).toBe(q.syntax);
      if (!q.syntax || q.local == null) return;
      const node = parseQuery(q.q);
      expect(node ? isLocal(node) : false).toBe(q.local);
      if (!q.local || !node || !q.names) return;
      const got = cases.cards.map((card, oi) => ({ card, oi })).filter(({ oi }) => {
        if (!usesPrinting(node)) return matches(node, c, oi, null);
        for (let p = c.pFirst[oi]; p < c.pFirst[oi] + c.pCount[oi]; p++) if (matches(node, c, oi, p)) return true;
        return false;
      }).map(({ card }) => card.name).sort();
      expect(got).toEqual([...q.names].sort());
      // The full local search finds the same cards.
      expect(localSearch(node, c).hits.map((oi) => c.oName[oi]).sort()).toEqual([...q.names].sort());
    });
  }

  it("a set term shows the printing it matched", () => {
    const node = parseQuery("s:m11")!;
    const r = localSearch(node, c);
    expect(r.hits.map((oi) => c.oName[oi])).toEqual(["Lightning Bolt"]);
    expect(c.pSet[r.covers.get(r.hits[0])!]).toBe("m11");
  });

  it("a plain name runs the ranked name search", async () => {
    const r = await runCardSearch("bolt", c);
    expect(r.remote).toBe(false);
    expect(r.hits.map((oi) => c.oName[oi])).toEqual(["Lightning Bolt"]);
  });
});

describe("Advanced form (shared cases)", () => {
  for (const a of cases.advanced) {
    it(a.query, () => {
      const f = a.fields;
      const fields = {
        ...EMPTY_ADVANCED,
        name: f.name ?? "", text: f.text ?? "", type: f.type ?? "", colors: Array.from(f.colors ?? ""),
        colorMode: (f.colorMode ?? "including") as typeof EMPTY_ADVANCED.colorMode, mvOp: f.mvOp ?? "=", mv: f.mv ?? "",
        rarities: Array.from(f.rarities ?? ""), set: f.set ?? "", format: f.format ?? "",
      };
      expect(advancedQuery(fields)).toBe(a.query);
      // What the form writes always runs locally unless it searches card text.
      if (!fields.text) expect(isLocal(parseQuery(advancedQuery(fields))!)).toBe(true);
    });
  }
});

describe("Library polish", () => {
  it("lists printings earliest first; same day keeps the older pack position first", () => {
    const pack = [
      "#t1catalog\t1\tv\t1\t4",
      "O\t0\to0\tX\tx\tInstant\t\t0\t\tX",
      "P\tnew\t0\tx\t1\ten\tc\tn\t2024-01-01\t\t1\t",
      "P\tmid-b\t0\tx\t1\ten\tc\tn\t2010-07-16\t\t1\t",
      "P\tmid-a\t0\tx\t1\ten\tc\tn\t2010-07-16\t\t1\t",
      "P\told\t0\tx\t1\ten\tc\tn\t1993-08-05\t\t1\t",
    ].join("\n");
    const c = parsePack("v", pack);
    expect([0, 3, 1, 2].sort((a, b) => oldestFirst(c, a, b)).map((p) => c.pId[p])).toEqual(["old", "mid-a", "mid-b", "new"]);
  });

  it("collapses printings by default; Expand all opens every card and one can still close", () => {
    let d = COLLAPSED;
    expect(isOpen(d, "a")).toBe(false);
    d = toggleOne(d, "a");
    expect(isOpen(d, "a")).toBe(true);
    d = setAll(true);
    expect(isOpen(d, "a") && isOpen(d, "b")).toBe(true);
    d = toggleOne(d, "b");
    expect(isOpen(d, "b")).toBe(false);
    d = setAll(false);
    expect(isOpen(d, "a") || isOpen(d, "b")).toBe(false);
  });

  it("groups a list's lines one row per card and section, most copies leading", () => {
    const line = (cardId: string, oracleId: string, board: string, qty: number, finish = "nonfoil") => ({ cardId, oracleId, board, qty, finish });
    const groups = lineGroups([line("b1", "Bolt", "main", 1), line("b2", "Bolt", "main", 3), line("b1", "Bolt", "main", 1, "foil"),
                               line("b1", "Bolt", "side", 2), line("o1", "Opt", "main", 4)]);
    expect(groups.map((g) => g.id)).toEqual(["main|Bolt", "side|Bolt", "main|Opt"]);
    expect(groups[0].qty).toBe(5);
    expect(groups[0].lines[0].cardId).toBe("b2");
    expect(groups[0].lines.length).toBe(3);
  });

  it("sorts unpriced cards first in Price", () => {
    const prices = [2, null, 10];
    expect(prices.map((p, i) => ({ p, i })).sort((a, b) => priceRank(b.p) - priceRank(a.p)).map((x) => x.i)).toEqual([1, 2, 0]);
  });
});

describe("hero cards", () => {
  it("maps card detail contexts to scopes; Unsorted has none", () => {
    expect(scopeOf(undefined, "unsorted")).toEqual({ kind: "collection" });
    expect(scopeOf({ list: "l1" }, "unsorted")).toEqual({ kind: "list", id: "l1" });
    expect(scopeOf({ binder: "b1" }, "unsorted")).toEqual({ kind: "binder", id: "b1" });
    expect(scopeOf({ binder: "unsorted" }, "unsorted")).toBeNull();
    expect(scopeKey({ kind: "list", id: "L1" })).toBe("list:l1");
  });

  it("toggles in pick order, up to the limit", () => {
    expect(toggledList(["a"], "b")).toEqual(["a", "b"]);
    expect(toggledList(["a", "b"], "a")).toEqual(["b"]);
    const full = Array.from({ length: HERO_LIMIT }, (_, i) => `h${i}`);
    expect(toggledList(full, "x")).toBeNull();
    expect(toggledList(full, "h3")).toHaveLength(HERO_LIMIT - 1);
  });

  it("shows the printing a place holds, else the card's cover", () => {
    const c = catalog();
    const bolt = c.oId[0], sol = c.oId[4];
    // Holds the M11 Bolt; Sol Ring isn't held, so its cover (the original, LEA) shows. Order follows the heroes.
    const ps = heroPrintings(c, [sol, bolt, "unknown"], ["p0-1"]);
    expect(ps.map((p) => `${c.pSet[p]}`)).toEqual(["lea", "m11"]);
  });
});
