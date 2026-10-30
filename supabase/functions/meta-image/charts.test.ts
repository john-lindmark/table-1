// meta-image: the Discord bot's Insights pictures (contract/discord-2026-10-29.md § Insights images).
import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { cellOf, credit, deckPicture, gridFor, heat, matchupsPicture, type Pack, rowsOf, wilson, winratesPicture } from "./charts.ts";
import { parseRequest } from "./request.ts";

const read = (f: string) => JSON.parse(Deno.readTextFileSync(new URL(`../../../testdata/${f}`, import.meta.url)));
const modern = () => read("insights/constructed-modern.json") as Pack;
const names = (svg: string) => [...svg.matchAll(/>([^<]+)<\/text>/g)].map((m) => m[1]);

Deno.test("heat matches the apps' shared cases", () => {
  for (const c of read("insight-charts/cases.json").heat) assertEquals(heat(c.in[0], c.in[1]), c.out);
});

Deno.test("95% Wilson range", () => {
  const [lo, hi] = wilson(36, 56);
  assertEquals([lo.toFixed(3), hi.toFixed(3)], ["0.512", "0.755"]);
  assertEquals(wilson(0, 0), [0, 1]);
});

Deno.test("the window's own grid, else the pack's 90 days", () => {
  const p = modern();
  assertEquals(gridFor(p, "big", 30).days, 90);
  const own = { archetypes: [1], rows: [1, 0], cells: [[1, 0, 3, 2, 0]] as [number, number, number, number, number][] };
  p.tiers.big.windows["30"].matchups = own;
  assertEquals(gridFor(p, "big", 30), { m: own, tier: "big", days: 30 });
});

Deno.test("credit names every source", () => {
  assertEquals(credit(["mtgo", "topdeck", "melee"]), "Results from Magic Online, TopDeck.gg and Melee");
  assertEquals(credit([]), "Results from Magic Online");
});

Deno.test("grid: a row per archetype, a column per most-played one, records in the squares", () => {
  const p = modern();
  const pic = matchupsPicture(p, "all", 90);
  const t = names(pic.svg);
  assertEquals(pic.width, 1600);
  assertStringIncludes(pic.svg, "MODERN MATCHUPS");
  assert(t.includes("Boros Land Destruction"), "rows below the top 10 are drawn");
  assert(t.includes("Other"));
  const c = cellOf(p.matchups, 11, 1)!;   // Boros Land Destruction against the first column
  assert(t.includes(`${c.wins}-${c.losses}${c.draws ? `-${c.draws}` : ""}`));
  assertEquals(rowsOf(p.matchups).length, 23);
});

Deno.test("grid: nothing in the window says so", () => {
  const p = modern();
  p.tiers.big.windows["7"].matchups = { archetypes: [], rows: [], cells: [] };
  assertStringIncludes(matchupsPicture(p, "big", 7).svg, "No matches between known decks in this window yet.");
});

Deno.test("deck: matchups with 30+ matches first, best to worst; fewer than 5 left out", () => {
  const p = modern();
  const t = names(deckPicture(p, "all", 90, 11).svg).filter((s) => / \(\d+\.\d%\)$/.test(s));
  const rates = t.map((s) => Number(/\((\d+\.\d)%\)/.exec(s)![1]));
  const sizes = t.map((s) => s.split(" ")[0].split("-").slice(0, 2).reduce((a, b) => a + Number(b), 0));
  const firstFaded = sizes.findIndex((n) => n < 30);
  assert(firstFaded > 0 && sizes.slice(firstFaded).every((n) => n < 30 && n >= 5));
  for (const part of [rates.slice(0, firstFaded), rates.slice(firstFaded)]) {
    assertEquals(part, [...part].sort((a, b) => b - a));
  }
  assertStringIncludes(deckPicture(p, "all", 90, 999).svg, "Too few matches");
});

Deno.test("win rates: best first, Other last, from 20 matches; an old pack says it predates the records", () => {
  const p = modern();
  const w = p.tiers.all.windows["30"];
  assertStringIncludes(winratesPicture(p, "all", 30).svg, "Too few matches", "no rates, no records: nothing to draw");
  w.share[0].wr = 0.5;   // a pack from 28 October to 30 October: rates without records
  assertStringIncludes(winratesPicture(p, "all", 30).svg, "predates win-rate records");
  w.share = [
    { a: 0, share: 0.1, decks: 10, rec: [70, 30, 0] },
    { a: 1, share: 0.2, decks: 20, rec: [40, 60, 0] },
    { a: 11, share: 0.1, decks: 10, rec: [36, 20, 0] },
    { a: 18, share: 0.1, decks: 10, rec: [5, 5, 0] },
  ];
  const t = names(winratesPicture(p, "all", 30).svg);
  const rows = ["Boros Land Destruction", "Broodscale Combo", "Eldrazi Bloodchief Combo", "Other", "Izzet Prowess"].filter((n) => t.includes(n));
  assertEquals(rows, ["Boros Land Destruction", "Eldrazi Bloodchief Combo", "Other"]);
  assert(t.indexOf("Boros Land Destruction") < t.indexOf("Eldrazi Bloodchief Combo") && t.indexOf("Eldrazi Bloodchief Combo") < t.indexOf("Other"));
  assert(t.includes("36-20-0 (64.3%)"));
});

Deno.test("addresses", () => {
  const u = (s: string) => parseRequest(new URL(`https://x/functions/v1/meta-image/${s}`));
  assertEquals(u("modern/matchups.png?tier=big&days=7&v=1"), { format: "modern", kind: "matchups", tier: "big", days: 7, a: null });
  assertEquals(u("pauper/winrates.png"), { format: "pauper", kind: "winrates", tier: "all", days: 30, a: null });
  assertEquals(u("modern/deck.png?a=11&days=45"), { format: "modern", kind: "deck", tier: "all", days: 30, a: 11 });
  assertEquals(u("modern/deck.png"), null);
  assertEquals(u("../secrets/matchups.png"), null);
  assertEquals(u("modern/other.png"), null);
});
