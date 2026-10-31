// Singleton fields filed as Vintage or Legacy (7-point Highlander, Commander) are skipped; real fields and Canadian
// Highlander are read. The Legacy field is a real Melee file (testdata/insights/melee).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { parseCacheEvent, type CacheFile } from "./cache.ts";
import { parseTournament, type TdTournament } from "./topdeck.ts";
import { singletonDeck, singletonField } from "./singleton.ts";

const legacy = JSON.parse(Deno.readTextFileSync(new URL(
  "../../../testdata/insights/melee/1k-legacy-scg-con-hartford-friday-1000-am-461686-2026-10-23.json", import.meta.url))) as CacheFile;
const enabled = [
  { format: "legacy", name: "Legacy", topdeck_min: 32 }, { format: "vintage", name: "Vintage", topdeck_min: 32 },
  { format: "canlander", name: "Canadian Highlander", topdeck_min: 16 },
];
// 60 different cards (a Highlander list), with its basics at several copies.
const highlander = (seat: number) => [
  ...Array.from({ length: 52 }, (_, i) => ({ Count: 1, CardName: `Card ${seat}-${i}` })),
  { Count: 3, CardName: "Island" }, { Count: 3, CardName: "Snow-Covered Swamp" }, { Count: 2, CardName: "Wastes" },
];

Deno.test("deck: two non-basic cards at more than one copy is still singleton, three isn't; basics don't count", () => {
  assert(singletonDeck([["Island", 8], ["Mountain", 7], ["Sol Ring", 1], ["Lightning Bolt", 2], ["Brainstorm", 2]]));
  assert(!singletonDeck([["Lightning Bolt", 2], ["Brainstorm", 2], ["Ponder", 4]]));
});

Deno.test("a real Legacy field is read", () => {
  const ev = parseCacheEvent("legacy", legacy, enabled);
  assertEquals(ev?.format, "legacy");
  assert(ev!.decks.length > 20);
});

Deno.test("a Highlander field filed as Vintage is skipped, unless under half its decks are singleton", () => {
  const players = legacy.Decks!.map((d) => d.Player);
  const vintage = (singletons: number): CacheFile => ({
    ...legacy, Tournament: { ...legacy.Tournament, Formats: "Vintage" },
    Decks: legacy.Decks!.map((d, i) => i < singletons ? { ...d, Mainboard: highlander(i) } : d),
  });
  assertEquals(parseCacheEvent("hl", vintage(players.length), enabled), null);
  assertEquals(parseCacheEvent("hl", vintage(Math.ceil(players.length / 2)), enabled), null);
  assertEquals(parseCacheEvent("hl", vintage(Math.ceil(players.length / 2) - 1), enabled)?.format, "vintage");
});

Deno.test("TopDeck: a Commander-sized singleton field is skipped; Canadian Highlander is read", () => {
  const t: TdTournament = {
    TID: "t1", tournamentName: "Bracket 3 1v1", startDate: 1_790_000_000, topCut: 0,
    standings: Array.from({ length: 40 }, (_, s) => ({
      id: `p${s}`, wins: 3, losses: 1, draws: 0,
      deckObj: { Mainboard: Object.fromEntries(Array.from({ length: 99 }, (_, i) => [`Card ${s}-${i}`, { count: 1 }])) },
    })),
  } as unknown as TdTournament;
  assertEquals(parseTournament(t, "vintage"), null);
  assertEquals(parseTournament(t, "canlander")?.decks.length, 40);
  assert(!singletonField("canlander", parseTournament(t, "canlander")!.decks));
});
