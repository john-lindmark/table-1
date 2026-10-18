import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { describe, expect, it, vi } from "vitest";

vi.mock("./supabaseClient", () => ({ supabase: {} }));
const { parsePack } = await import("./catalog");
const { ImportResolver, parseCsv } = await import("./collectionCsv");

// A 20,000-line ManaBox export of real printings, parsed and matched against the full test catalog. Always checks
// the result; with T1_PERF=1 (./test.sh perf) also enforces budgets, ~5x a Mac's timings (2026-10-17), so they catch
// an accidental quadratic pass, not noise. Same file as apps/ios/Table1Tests CollectionImportPerfTests.
const PERF = !!process.env.T1_PERF;
const BUDGET = { parseMs: 150, matchMs: 400 }; // measured 30 ms and 32–80 ms

const root = new URL("../../../testdata/", import.meta.url);
const pack = gunzipSync(readFileSync(new URL("scan/catalog.tsv.gz", root))).toString("utf8");
const catalog = parsePack("test", pack);

function bigFile(lines: number): string {
  const out = ["Binder Name,Binder Type,Name,Set code,Set name,Collector number,Foil,Rarity,Quantity,ManaBox ID,Scryfall ID,Purchase price,Misprint,Altered,Condition,Language,Purchase price currency"];
  let n = 0;
  for (let p = 0; p < catalog.printings && n < lines; p++) {
    if (catalog.pLang[p] !== "en") continue;
    const name = catalog.oName[catalog.pOracle[p]];
    const q = /[",]/.test(name) ? `"${name.replace(/"/g, '""')}"` : name;
    const foil = catalog.pFinishes[p].includes("f") && n % 5 === 0 ? "foil" : "normal";
    out.push(`Binder,binder,${q},${catalog.pSet[p].toUpperCase()},Some Set,${catalog.pCn[p]},${foil},common,${(n % 4) + 1},${n},${catalog.pId[p]},0.10,false,false,near_mint,en,USD`);
    n++;
  }
  return out.join("\n");
}

describe("collection import perf", () => {
  it("parses and matches a 20,000-line file", () => {
    const text = bigFile(20_000);
    const t0 = performance.now();
    const parsed = parseCsv(text);
    const parseMs = performance.now() - t0;
    const t1 = performance.now();
    const r = new ImportResolver(catalog, []).resolveAll(parsed.rows);
    const matchMs = performance.now() - t1;
    console.log(`perf web import parse 20k lines: ${parseMs.toFixed(0)} ms (budget ${BUDGET.parseMs})`);
    console.log(`perf web import match 20k lines: ${matchMs.toFixed(0)} ms (budget ${BUDGET.matchMs})`);
    expect(parsed.rows).toHaveLength(20_000);
    expect(r.matched.length).toBe(20_000); // every line carries its printing's id
    if (PERF) {
      expect(parseMs).toBeLessThan(BUDGET.parseMs);
      expect(matchMs).toBeLessThan(BUDGET.matchMs);
    }
  });

  it("matches 20,000 lines by set and number when the ids are unknown", () => {
    const text = bigFile(20_000).replace(/,p\d+,0\.10,/g, ",,0.10,");
    const parsed = parseCsv(text);
    const t0 = performance.now();
    const r = new ImportResolver(catalog, []).resolveAll(parsed.rows);
    const ms = performance.now() - t0;
    console.log(`perf web import match 20k lines by set + number: ${ms.toFixed(0)} ms (budget ${BUDGET.matchMs})`);
    expect(r.matched.length).toBeGreaterThan(19_900);
    if (PERF) expect(ms).toBeLessThan(BUDGET.matchMs);
  });
});
