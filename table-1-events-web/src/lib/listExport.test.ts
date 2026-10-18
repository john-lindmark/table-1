import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { parsePack } = await import("./catalog");
const { CUBE_COBRA_HEADER, exportFileName, exportLines, exportName, exportPrinting, renderList } = await import("./listExport");
const { resolveImport } = await import("../screens/ListImport");
type ExportLine = import("./listExport").ExportLine;
type ExportFormat = import("./listExport").ExportFormat;
type Entry = import("./lists").Entry;

/* Deck and cube export (contract/lists-2026-10-15.md, Export). Same cases as apps/ios/Table1Tests/ListExportTests.swift
   and Android's ListExportTest. testdata/list-export/lists.json is a deck and a cube of real printings from the test
   pack; each format must come out as the file next to it byte for byte. list-import's parser reads those files as
   parsed.json (supabase/functions/list-import/parse.test.ts), and here those lines resolve back to the same entries:
   export → paste → import gives the list back. */

const root = new URL("../../../testdata/", import.meta.url);
const file = (name: string) => readFileSync(new URL(`list-export/${name}`, root), "utf8");
type Raw = [string, Entry["board"], number, ("foil" | "etched")?];
const fixture = JSON.parse(file("lists.json")) as {
  cards: Record<string, { name: string; type_line: string; cmc: number; colors: string; set: string; cn: string; rarity: string }>;
  deck: { entries: Raw[] };
  cube: { entries: Raw[] };
};
const entries = (raw: Raw[]): Entry[] => raw.map(([cardId, board, qty, finish]) => (finish ? { cardId, board, qty, finish } : { cardId, board, qty }));
const lines = (raw: Raw[]): ExportLine[] => entries(raw).map((e) => {
  const c = fixture.cards[e.cardId];
  return { card: { name: c.name, typeLine: c.type_line, cmc: c.cmc, colors: c.colors, set: c.set, cn: c.cn, rarity: c.rarity },
           board: e.board, qty: e.qty, finish: e.finish ?? "nonfoil" };
});
const catalog = parsePack("test", gunzipSync(readFileSync(new URL("scan/catalog.tsv.gz", root))).toString("utf8"));
const key = (e: Entry) => `${e.board}|${e.cardId}|${e.finish ?? "nonfoil"}|${e.qty}`;
const keys = (es: Entry[]) => es.map(key).sort();

describe("renderList", () => {
  const cases: [string, "deck" | "cube", ExportFormat][] = [
    ["deck.arena.txt", "deck", "arena"], ["deck.moxfield.txt", "deck", "moxfield"], ["deck.mtgo.txt", "deck", "mtgo"],
    ["deck.text.txt", "deck", "text"], ["cube.cubecobra.csv", "cube", "cubecobra"], ["cube.text.txt", "cube", "text"],
  ];
  for (const [name, kind, format] of cases) {
    it(`writes ${name}`, () => {
      // Input order mustn't matter.
      expect(renderList(lines(fixture[kind].entries).reverse(), kind, format)).toBe(file(name));
    });
  }

  it("names cards the way other apps do", () => {
    const card = (name: string, typeLine: string) => ({ name, typeLine, cmc: 0, colors: "", set: "", cn: "", rarity: "" });
    expect(exportName(card("Fire // Ice", "Instant // Instant"))).toBe("Fire // Ice");
    expect(exportName(card("Alive // Well", "Enchantment — Room // Enchantment — Room"))).toBe("Alive // Well");
    expect(exportName(card("There // They're // Their", "Instant — Lesson // Instant — Lesson // Instant — Lesson"))).toBe("There // They're // Their");
    expect(exportName(card("Bonecrusher Giant // Stomp", "Creature — Giant // Instant — Adventure"))).toBe("Bonecrusher Giant");
    expect(exportName(card("Petty Theft Test // Theft", "Instant // Instant — Adventure"))).toBe("Petty Theft Test");
    expect(exportName(card("Agadeem's Awakening // Agadeem, the Undercrypt", "Sorcery // Land"))).toBe("Agadeem's Awakening");
    expect(exportPrinting({ ...card("Jaya", ""), set: "pmps08", cn: "a1 2007" })).toBeNull();
    expect(exportPrinting({ ...card("Jaya", ""), set: "pmps08", cn: "a1_2007" })).toBe("(PMPS08) a1_2007");
  });

  it("handles empty lists and file names", () => {
    expect(renderList([], "deck", "arena")).toBe("");
    expect(renderList([], "cube", "cubecobra")).toBe(CUBE_COBRA_HEADER + "\r\n");
    expect(exportFileName('Izzet: "Tempo" / test', "deck", "mtgo")).toBe("Izzet Tempo test.txt");
    expect(exportFileName("///", "cube", "cubecobra")).toBe("cube.csv");
  });
});

describe("exportLines", () => {
  it("takes each card from the catalog and counts the ones it doesn't have", () => {
    const r = exportLines(catalog, [...entries(fixture.deck.entries), { cardId: "not-a-card", board: "main", qty: 3 }]);
    expect(r.left).toBe(3);
    // The test pack trims cmc and colors.
    const pick = (l: ExportLine) => [l.card.name, l.card.typeLine, l.card.set, l.card.cn, l.card.rarity, l.board, l.qty, l.finish];
    expect(r.lines.map(pick)).toEqual(lines(fixture.deck.entries).map(pick));
  });
});

describe("round trip", () => {
  const parsed = JSON.parse(file("parsed.json")) as Record<string, Parameters<typeof resolveImport>[1]>;
  const deck = entries(fixture.deck.entries);
  const cube = entries(fixture.cube.entries);

  it("Moxfield and Cube Cobra come back exactly", () => {
    expect(keys(resolveImport(catalog, parsed["deck.moxfield.txt"], "deck").entries)).toEqual(keys(deck));
    expect(keys(resolveImport(catalog, parsed["cube.cubecobra.csv"], "cube").entries)).toEqual(keys(cube));
  });

  it("Arena comes back with the same printings and sections, non-foil, without Considering", () => {
    const want = new Map<string, Entry>();
    for (const e of deck) {
      if (e.board === "maybe") continue;
      const k = `${e.board}|${e.cardId}`;
      want.set(k, { cardId: e.cardId, board: e.board, qty: (want.get(k)?.qty ?? 0) + e.qty });
    }
    expect(keys(resolveImport(catalog, parsed["deck.arena.txt"], "deck").entries)).toEqual(keys([...want.values()]));
  });

  it("names-only formats find every card with the same counts per section", () => {
    const counts = (es: Entry[], mtgo = false) => es.reduce<Record<string, number>>((m, e) => {
      const b = mtgo && e.board === "commander" ? "side" : e.board;
      m[b] = (m[b] ?? 0) + e.qty;
      return m;
    }, {});
    for (const [name, kind, want, mtgo] of [
      ["deck.text.txt", "deck", deck, false], ["cube.text.txt", "cube", cube, false],
      ["deck.mtgo.txt", "deck", deck.filter((e) => e.board !== "maybe"), true],
    ] as const) {
      const r = resolveImport(catalog, parsed[name], kind);
      expect(r.missing, name).toEqual([]);
      expect(counts(r.entries, mtgo), name).toEqual(counts([...want], mtgo));
    }
  });
});
