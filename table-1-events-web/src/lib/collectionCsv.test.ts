import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { parsePack } = await import("./catalog");
const {
  CsvError, ImportResolver, exportCsv, importItems, parseCondition, parseCsv, parseFinish, parseLanguage, parseQuantity,
} = await import("./collectionCsv");
type ImportRow = import("./collectionCsv").ImportRow;
type ExportCard = import("./collectionCsv").ExportCard;

/* Collection CSV import and export (contract/collection-import-2026-10-17.md). Same cases as
   apps/ios/Table1Tests/CollectionCSVTests.swift. The fixtures in testdata/collection-import are the same 24 cards as
   seven apps export them; matching runs against the real catalog pack in testdata/scan (shortened ids, so lines match
   by set + collector number or set + name there, as they would without Scryfall ids). */

const root = new URL("../../../testdata/", import.meta.url);
const fixture = (name: string) => readFileSync(new URL(`collection-import/${name}`, root), "utf8");
const expected = JSON.parse(fixture("expected.json")) as {
  unmatched: string;
  cards: { set: string; cn: string; name: string; finish: string; condition: string; lang: string; qty: number }[];
};
const setNames = JSON.parse(fixture("sets.json")) as { code: string; name: string }[];
const catalog = parsePack("test", gunzipSync(readFileSync(new URL("scan/catalog.tsv.gz", root))).toString("utf8"));

describe("parseCsv", () => {
  it("handles quotes, line ends and a BOM", () => {
    const p = parseCsv('﻿Name,Set code,Collector number,Quantity\r\n"Aragorn, the Uniter",LTR,192,1\r\n"Say ""Hi""\nTwice",M11,149,2\r\n\r\n');
    expect(p.rows.map((r) => r.name)).toEqual(["Aragorn, the Uniter", 'Say "Hi"\nTwice']);
    expect(p.rows.map((r) => r.setCode)).toEqual(["ltr", "m11"]);
    expect(p.rows.map((r) => r.qty)).toEqual([1, 2]);
    expect(p.rows.map((r) => r.line)).toEqual([2, 3]);
  });

  it("finds the delimiter", () => {
    const tab = parseCsv("Name\tSet\tQuantity\nLightning Bolt\tm11\t3\n");
    expect(tab.rows[0].qty).toBe(3);
    expect(tab.rows[0].setCode).toBe("m11");
    const semi = parseCsv("Name;Edition;Count\nLightning Bolt;Magic 2011;2\n");
    expect(semi.rows[0].setName).toBe("Magic 2011");
    expect(semi.rows[0].qty).toBe(2);
    const sep = parseCsv('"sep=;"\nName;Quantity\nShock;4\n');
    expect(sep.rows[0].name).toBe("Shock");
    expect(sep.rows[0].line).toBe(3);
  });

  it("refuses a file with no name column", () => {
    expect(() => parseCsv("Set,Quantity\nm11,1\n")).toThrow(new CsvError("This file has no card name column."));
    expect(() => parseCsv("")).toThrow(CsvError);
  });

  it.each([
    ["manabox.csv", "manabox"], ["moxfield.csv", "moxfield"], ["archidekt.csv", "archidekt"], ["deckbox.csv", "deckbox"],
    ["dragonshield.csv", "dragonshield"], ["tcgplayer.csv", "tcgplayer"], ["delverlens.csv", "delverlens"],
  ])("detects %s", (file, format) => {
    const p = parseCsv(fixture(file));
    expect(p.format).toBe(format);
    expect(p.rows).toHaveLength(25); // 24 cards and the unknown line
  });

  it("reads other files by column name", () => expect(parseCsv("Card,Qty\nShock,1\n").format).toBe("other"));

  it("reads quantities", () => {
    expect(parseQuantity("2x")).toBe(2);
    expect(parseQuantity(" 12 ")).toBe(12);
    expect(parseQuantity("")).toBe(1);
    expect(parseQuantity("lots")).toBeNull();
    expect(parseQuantity("-1")).toBeNull();
    const p = parseCsv("Name,Quantity\nShock,lots\nBolt,0\nOpt,\n");
    expect(p.rows.map((r) => r.name)).toEqual(["Shock", "Opt"]);
    expect(p.rows[0].problem).toBe("Quantity isn't a number");
    expect(p.rows[1].qty).toBe(1);
  });

  it.each([
    ["", "nonfoil"], ["normal", "nonfoil"], ["Normal", "nonfoil"], ["Non-foil", "nonfoil"], ["false", "nonfoil"],
    ["foil", "foil"], ["Foil", "foil"], ["Double Rainbow Foil", "foil"], ["true", "foil"], ["1", "foil"],
    ["etched", "etched"], ["Foil Etched", "etched"],
  ])("finish %j → %s", (v, f) => expect(parseFinish(v)).toBe(f));

  it.each([
    ["Mint", "NM"], ["Near Mint", "NM"], ["NM", "NM"], ["", "NM"], ["weird", "NM"], ["Lightly Played", "LP"],
    ["Good (Lightly Played)", "LP"], ["Excellent", "LP"], ["Moderately Played", "MP"], ["Played", "MP"],
    ["Heavily Played", "HP"], ["Damaged", "DMG"], ["Poor", "DMG"], ["D", "DMG"],
  ])("TCGplayer scale %j → %s", (v, c) => expect(parseCondition(v, false)).toBe(c));

  it.each([
    ["mint", "NM"], ["near_mint", "NM"], ["NearMint", "NM"], ["excellent", "LP"], ["good", "LP"], ["light_played", "MP"],
    ["LightPlayed", "MP"], ["played", "HP"], ["Played", "HP"], ["poor", "DMG"], ["Damaged", "DMG"],
  ])("Cardmarket scale %j → %s", (v, c) => expect(parseCondition(v, true)).toBe(c));

  it.each([
    ["English", "en"], ["EN", "en"], ["de", "de"], ["German", "de"], ["Japanese", "ja"], ["jp", "ja"], ["Korean", "ko"],
    ["Chinese Simplified", "zhs"], ["Simplified Chinese", "zhs"], ["zh_CN", "zhs"], ["Traditional Chinese", "zht"],
    ["zh-TW", "zht"], ["Portuguese (Brazil)", "pt"], ["Klingon", "en"], ["", "en"],
  ])("language %j → %s", (v, l) => expect(parseLanguage(v)).toBe(l));

  it("reads each format's own columns", () => {
    expect(parseCsv(fixture("moxfield.csv")).rows[0].setCode).toBe("m11");
    const deckbox = parseCsv(fixture("deckbox.csv")).rows[0];
    expect(deckbox.setName).toBe("Magic 2011");
    expect(deckbox.setCode).toBe("m11");
    expect(parseCsv(fixture("delverlens.csv")).rows[0].setName).toBe("Magic 2011");
    const tcg = parseCsv(fixture("tcgplayer.csv")).rows;
    expect(tcg[3].name).toBe("Brazen Borrower");
    expect(tcg.find((r) => r.cn === "300")?.finish).toBe("etched");
    const ds = parseCsv('"sep=,"\nFolder Name,Quantity,Card Name,Set Code,Card Number,Printing\nA,1,Azorius Herald,GK2_AZORIU,2,Normal\n');
    expect(ds.rows[0].setCode).toBe("gk2");
    const seller = parseCsv("TCGplayer Id,Product Name,Set Name,Number,Condition,Total Quantity\n1,Shock,M19,156,Near Mint Foil,2\n");
    expect(seller.format).toBe("tcgplayer");
    expect(seller.rows[0]).toMatchObject({ finish: "foil", condition: "NM", qty: 2 });
  });
});

describe("exportCsv", () => {
  const cards: ExportCard[] = expected.cards.map((c) => ({
    name: c.name, set: c.set, setName: `Set ${c.set}`, cn: c.cn, rarity: "r", cardId: `id-${c.set}-${c.cn}`,
    finish: c.finish as ExportCard["finish"], condition: c.condition as ExportCard["condition"], lang: c.lang, qty: c.qty,
  }));
  const key = (s: string | null, cn: string | null, f: string, c: string, l: string, q: number) => `${s}|${cn}|${f}|${c}|${l}|${q}`;

  it.each(["moxfield", "manabox"] as const)("%s layout reads back to the same items", (layout) => {
    const p = parseCsv(exportCsv(cards, layout));
    expect(p.format).toBe(layout);
    expect(new Set(p.rows.map((r) => key(r.setCode, r.cn, r.finish, r.condition, r.lang, r.qty))))
      .toEqual(new Set(cards.map((c) => key(c.set, c.cn, c.finish, c.condition, c.lang, c.qty))));
    expect(new Set(p.rows.map((r) => r.name))).toEqual(new Set(cards.map((c) => c.name)));
    if (layout === "manabox") expect(new Set(p.rows.map((r) => r.scryfallId))).toEqual(new Set(cards.map((c) => c.cardId)));
  });

  it("writes the apps' headers", () => {
    expect(exportCsv(cards, "moxfield").startsWith('"Count","Tradelist Count","Name","Edition"')).toBe(true);
    expect(exportCsv(cards, "manabox").startsWith("Binder Name,Binder Type,Name,Set code,Set name,Collector number,Foil,Rarity,Quantity")).toBe(true);
  });
});

describe("ImportResolver", () => {
  const resolve = (file: string) => new ImportResolver(catalog, setNames).resolveAll(parseCsv(fixture(file)).rows);
  const oracleName = (p: number | undefined) => (p == null ? undefined : catalog.oName[catalog.pOracle[p]]);

  it.each(["manabox.csv", "moxfield.csv", "archidekt.csv", "deckbox.csv", "dragonshield.csv", "tcgplayer.csv"])(
    "%s lands on the exact printing, finish, condition and language", (file) => {
      const r = resolve(file);
      expect(r.unmatched.map((u) => u.name)).toEqual([expected.unmatched]);
      expect(r.matched).toHaveLength(expected.cards.length);
      r.matched.forEach((got, i) => {
        const want = expected.cards[i];
        expect(`${catalog.pSet[got.p]} ${catalog.pCn[got.p]}`, `line ${got.row.line}`).toBe(`${want.set} ${want.cn}`);
        expect(got.finish, `line ${got.row.line}`).toBe(want.finish);
        expect(got.row.condition, `line ${got.row.line}`).toBe(want.condition);
        expect(got.row.lang, `line ${got.row.line}`).toBe(want.lang);
        expect(got.row.qty).toBe(want.qty);
      });
    });

  it("Delver Lens matches by set name (no collector numbers; its foil column can't say etched)", () => {
    const r = resolve("delverlens.csv");
    expect(r.unmatched.map((u) => u.name)).toEqual([expected.unmatched]);
    r.matched.forEach((got, i) => {
      const want = expected.cards[i];
      expect(got.how).toBe("setName");
      expect(catalog.pSet[got.p]).toBe(want.set);
      expect(oracleName(got.p)).toBe(want.name);
      expect(got.finish).toBe(want.finish === "etched" ? "foil" : want.finish);
      expect(got.row.qty).toBe(want.qty);
    });
  });

  it("matches in order: set + number, set + name, name", () => {
    const res = new ImportResolver(catalog, setNames);
    const row = (name: string, o: Partial<ImportRow> = {}): ImportRow => ({
      line: 2, name, setCode: null, setName: null, cn: null, scryfallId: null, qty: 1, finish: "nonfoil", condition: "NM",
      lang: "en", problem: null, ...o,
    });
    const bolt = res.resolve(row("Lightning Bolt", { setCode: "m11", cn: "149" }))!;
    expect(bolt.how).toBe("setNumber");
    expect(catalog.pCn[bolt.p]).toBe("149");
    const wrong = res.resolve(row("Lightning Bolt", { setCode: "m11", cn: "1" }))!;
    expect(wrong.how).toBe("setName");
    expect(catalog.pCn[wrong.p]).toBe("149");
    expect(catalog.pCn[res.resolve(row("Armed", { setName: "Dragon's Maze", cn: "0122" }))!.p]).toBe("122");
    const named = res.resolve(row("Brazen Borrower"))!;
    expect(named.how).toBe("name");
    expect(oracleName(named.p)).toBe("Brazen Borrower // Petty Theft");
    expect(catalog.oOriginal[catalog.pOracle[named.p]]).toBe(named.p);
    expect(oracleName(res.resolve(row("Abbey Matron [Version 2]"))?.p)).toBe("Abbey Matron");
    expect(oracleName(res.resolve(row("Lightning Bolt (Borderless)"))?.p)).toBe("Lightning Bolt");
    expect(oracleName(res.resolve(row("Clue Token", { setCode: "tmh2", cn: "14" }))?.p)).toBe("Clue");
    expect(res.resolve(row("Lightning Bolt", { setCode: "zzz", cn: "1" }))?.how).toBe("name");
    expect(res.resolve(row("Totally Not A Card", { setCode: "zzz" }))).toBeNull();
    expect(res.resolve(row("Blasphemous Act", { setCode: "2xm", cn: "117", finish: "etched" }))?.finish).toBe("foil");
    const fixed = res.resolveAs(row("Totally Not A Card", { setCode: "m11" }), catalog.pOracle[bolt.p]);
    expect(fixed.how).toBe("fixed");
    expect(catalog.pSet[fixed.p]).toBe("m11");
  });

  it("sums lines on the same item", () => {
    const r = resolve("manabox.csv");
    const once = importItems(catalog, r.matched);
    const twice = importItems(catalog, [...r.matched, ...r.matched]);
    expect(twice).toHaveLength(once.length);
    expect(twice.reduce((n, it) => n + it.qty, 0)).toBe(2 * r.matched.reduce((n, l) => n + l.row.qty, 0));
  });
});
