// Real MTG_decklistcache Melee files (testdata/insights/melee, player names replaced) and GitHub listing shapes.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { cacheFormat, cacheItems, cacheRawUrl, cacheYears, hasTopEight, parseCacheEvent, type CacheFile } from "./cache.ts";

const dir = new URL("../../../testdata/insights/melee/", import.meta.url);
const file = (name: string) => JSON.parse(Deno.readTextFileSync(new URL(`${name}.json`, dir))) as CacheFile;
const enabled = [
  { format: "standard", name: "Standard", topdeck_min: 32 }, { format: "pioneer", name: "Pioneer", topdeck_min: 32 },
  { format: "modern", name: "Modern", topdeck_min: 32 }, { format: "pauper", name: "Pauper", topdeck_min: 32 },
  { format: "canlander", name: "Canadian Highlander", topdeck_min: 16 },
];
const now = Date.UTC(2026, 9, 29);

Deno.test("years: only those a year of history reaches, and only when their tree changed", () => {
  const entries = ["2023", "2024", "2025", "2026"].map((y) => ({ path: `${y}`, name: y, type: "dir", sha: `sha${y}` }));
  assertEquals(cacheYears(entries, {}, now).map((y) => y.year), ["2025", "2026"]);
  assertEquals(cacheYears(entries, { cache_melee_2025: "sha2025" }, now).map((y) => y.year), ["2026"]);
  assertEquals(cacheYears(entries, { cache_melee_2025: "sha2025", cache_melee_2026: "sha2026" }, now), []);
  assertEquals(cacheYears(entries, {}, Date.UTC(2027, 0, 5)).map((y) => y.year), ["2026"]);
});

Deno.test("items: the year's event files within a year, slugged with their blob sha", () => {
  const tree = [
    { path: "10", type: "tree", sha: "t" },
    { path: "10/25/weekly-pauper-bonn-487180-2026-10-25.json", type: "blob", sha: "0123456789abcdef0123" },
    { path: "10/25/notes.txt", type: "blob", sha: "x" },
  ];
  assertEquals(cacheItems("2026", tree, now), [{
    source: "melee", format: null, slug: "2026/10/25/weekly-pauper-bonn-487180-2026-10-25.json@0123456789ab",
    url: "https://raw.githubusercontent.com/fbettega/MTG_decklistcache/main/Tournaments/MTGmelee/2026/10/25/weekly-pauper-bonn-487180-2026-10-25.json",
  }]);
  // older than a year: left out
  assertEquals(cacheItems("2025", [{ path: "10/28/a.json", type: "blob", sha: "s" }], now), []);
  assertEquals(cacheItems("2025", [{ path: "10/30/a.json", type: "blob", sha: "s" }], now).length, 1);
  assertEquals(cacheRawUrl("2026/01/02/第13回.json").endsWith("/2026/01/02/%E7%AC%AC13%E5%9B%9E.json"), true);
});

Deno.test("format: exactly one enabled format by name, else none", () => {
  assertEquals(cacheFormat("Modern", enabled), "modern");
  assertEquals(cacheFormat(["Pauper"], enabled), "pauper");
  assertEquals(cacheFormat("Legacy", enabled), null);
  assertEquals(cacheFormat("Duel Commander", enabled), null);
  assertEquals(cacheFormat(["Modern", "Draft"], enabled), null);
  assertEquals(cacheFormat(undefined, enabled), null);
});

Deno.test("an RCQ with a top 8: every deck, records from standings, byes left out, the top 8 marked", () => {
  const ev = parseCacheEvent("pioneer-revival-rcq-476422-2026-10-02", file("pioneer-revival-rcq-476422-2026-10-02"), enabled)!;
  assertEquals([ev.source, ev.source_id, ev.format, ev.name, ev.kind, ev.on, ev.players, ev.complete],
               ["melee", "pioneer-revival-rcq-476422-2026-10-02", "pioneer", "Pioneer Revival RCQ", "paper", "2026-10-02", 32, true]);
  assertEquals(ev.url, "https://melee.gg/Tournament/View/476422");
  assertEquals(ev.decks.length, 32);
  const first = ev.decks.find((d) => d.player === "Player 1")!;
  assertEquals([first.rank, first.wins, first.losses, first.draws, first.top8], [1, 6, 1, 0, true]);
  assertEquals(first.main.reduce((n, [, q]) => n + q, 0), 60);
  assertEquals(first.side.reduce((n, [, q]) => n + q, 0), 15);
  assertEquals(ev.decks.filter((d) => d.top8).map((d) => d.rank).sort((a, b) => a! - b!), [1, 2, 3, 4, 5, 6, 7, 8]);
  assert(ev.matches.every((m) => m.a !== "-" && m.b !== "-"));
  assertEquals(ev.matches[0], { round: "Round 1", a: "Player 5", b: "Player 1", a_wins: 2, b_wins: 1, result: "a" });
  // the final (round 8): 2-0 for player 1
  assertEquals(ev.matches.at(-1), { round: "Round 8", a: "Player 1", b: "Player 2", a_wins: 2, b_wins: 0, result: "a" });
});

Deno.test("a 1-1 or 0-0-3 result is a draw", () => {
  const playset = Array.from({ length: 15 }, (_, i) => ({ Count: 4, CardName: `Card ${i}` }));
  const f: CacheFile = {
    Tournament: { Date: "2026-10-04T10:00:00+00:00", Name: "Draws", Uri: "u", Formats: "Modern" },
    Standings: Array.from({ length: 32 }, (_, i) => ({ Rank: i + 1, Player: `P${i}`, Wins: 0, Losses: 0, Draws: 0 })),
    Decks: [{ Player: "P0", Result: "1st Place", Mainboard: playset },
            { Player: "P1", Result: "2nd Place", Mainboard: playset }],
    Rounds: [{ RoundName: "Round 1", Matches: [{ Player1: "P0", Player2: "P1", Result: "1-1-1" }, { Player1: "P1", Player2: "P0", Result: "0-0-3" },
                                              { Player1: "P0", Player2: "P1", Result: "won" }] }],
  };
  const ev = parseCacheEvent("x", f, enabled)!;
  assertEquals(ev.matches.map((m) => m.result), ["draw", "draw"]);
  assertEquals(ev.complete, false);
});

Deno.test("top 8 seen through a missing semifinal or a third-place match; not in an elimination event", () => {
  const two = parseCacheEvent("modern-2k-rcq-476434-2026-10-04", file("modern-2k-rcq-476434-2026-10-04"), enabled)!;
  assertEquals([two.format, two.players, two.decks.length, two.complete], ["modern", 47, 44, false]);
  assertEquals(two.decks.filter((d) => d.top8).length, 8);
  const lcq = parseCacheEvent("recq-standard-scg-con-hartford-saturday-400-pm-462468-2026-10-24",
                              file("recq-standard-scg-con-hartford-saturday-400-pm-462468-2026-10-24"), enabled)!;
  assertEquals([lcq.format, lcq.players], ["standard", 41]);
  assertEquals(lcq.decks.filter((d) => d.top8).length, 0);
  const rank = new Map([["a", 1], ["b", 2], ["c", 3], ["d", 4], ["e", 5], ["f", 6], ["g", 7], ["h", 8], ["z", 20]]);
  const r = (...ms: string[]) => ({ matches: ms.map((m) => [m[0], m[1]] as [string, string]) });
  const swiss = r("az", "bz", "cz", "dz", "ez");
  assertEquals(hasTopEight([swiss, swiss, r("ah", "bg", "cf", "de"), r("ad", "bc"), r("ab")], rank), true);
  assertEquals(hasTopEight([swiss, swiss, r("ah", "bg", "cf", "de"), r("ad", "bc"), r("ab", "cd")], rank), true);
  assertEquals(hasTopEight([swiss, swiss, r("ah", "bg", "cf", "dz"), r("ad", "bc"), r("ab")], rank), false);
  assertEquals(hasTopEight([r("ah", "bg", "cf", "de"), r("ah", "bg", "cf", "de"), r("ad", "bc"), r("ab")], rank), false);
});

Deno.test("left out: another format, a field under the paper minimum, a championship's qualifier is not a championship", () => {
  assertEquals(parseCacheEvent("l", file("1k-legacy-scg-con-hartford-friday-1000-am-461686-2026-10-23"), enabled), null);
  assertEquals(parseCacheEvent("b", file("weekly-pauper-bonn-487180-2026-10-25"), enabled), null);
  const big = file("pioneer-revival-rcq-476422-2026-10-02");
  const named = (name: string) => parseCacheEvent("n", { ...big, Tournament: { ...big.Tournament, Name: name } }, enabled)!.kind;
  assertEquals(named("Regional Championship - SCG CON Los Angeles"), "championship");
  assertEquals(named("Regional Championship Qualifier at the shop"), "paper");
  assertEquals(named("Pro Tour Fracture"), "championship");
});
