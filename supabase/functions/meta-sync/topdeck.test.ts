// TopDeck answers in the documented shape (https://topdeck.gg/docs/tournaments-v2); not yet checked against a
// live answer (no key yet).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { deckLines, nextTopdeckWindow, parseTournament, tournamentsQuery, type TdTournament } from "./topdeck.ts";

const main60 = Object.fromEntries(Array.from({ length: 15 }, (_, i) => [`Card ${i}`, { count: 4 }]));

Deno.test("query: format, days, size and rounds", () => {
  const q = tournamentsQuery("Modern", 3);
  assertEquals(q.game, "Magic: The Gathering");
  assertEquals(q.format, "Modern");
  assertEquals(q.last, 3);
  assertEquals(q.participantMin, 32);
  assertEquals(q.rounds, true);
  assert(q.columns.includes("decklist"));
  const w = tournamentsQuery("Canadian Highlander", { start: 100, end: 200 }, 16);
  assertEquals([w.start, w.end, w.participantMin, "last" in w], [100, 200, 16, false]);
});

Deno.test("backfill windows: TopDeck-only formats first, then the least read, back a year, then done", () => {
  const now = Date.UTC(2026, 9, 25);
  const day = 86_400;
  const formats = [{ format: "modern", topdeckOnly: false }, { format: "canlander", topdeckOnly: true }];
  // nothing read yet: Canadian Highlander first, from 3 days back (the builds cover those) to 30 days before that
  assertEquals(nextTopdeckWindow(formats, {}, now), { format: "canlander", start: now / 1000 - 33 * day, end: now / 1000 - 3 * day });
  // Canadian Highlander read back a year (the last window stops at the year): Modern next
  const yearAgo = new Date(now - 365 * day * 1000).toISOString();
  assertEquals(nextTopdeckWindow(formats, { td_back_canlander: yearAgo }, now)?.format, "modern");
  const almost = new Date(now - 350 * day * 1000).toISOString();
  assertEquals(nextTopdeckWindow(formats, { td_back_canlander: almost }, now), { format: "canlander", start: now / 1000 - 365 * day, end: now / 1000 - 350 * day });
  // among formats with MTGO results, the one with the least history read
  const two = [{ format: "modern", topdeckOnly: false }, { format: "pauper", topdeckOnly: false }];
  assertEquals(nextTopdeckWindow(two, { td_back_modern: new Date(now - 60 * day * 1000).toISOString() }, now)?.format, "pauper");
  assertEquals(nextTopdeckWindow(two, { td_back_modern: yearAgo, td_back_pauper: yearAgo }, now), null);
});

Deno.test("deck lines from deckObj, from text, and none from a link", () => {
  assertEquals(deckLines({ deckObj: { Mainboard: { "Lightning Bolt": { count: 4 } }, Sideboard: { "Blood Moon": 2 } } }),
    { main: [["Lightning Bolt", 4]], side: [["Blood Moon", 2]] });
  assertEquals(deckLines({ decklist: "4 Lightning Bolt\n2 Mountain (M21) 270\n\nSideboard\n2 Blood Moon" }),
    { main: [["Lightning Bolt", 4], ["Mountain", 2]], side: [["Blood Moon", 2]] });
  assertEquals(deckLines({ decklist: "4x Opt\nSB: 1 Negate" }), { main: [["Opt", 4]], side: [["Negate", 1]] });
  assertEquals(deckLines({ decklist: "https://moxfield.com/decks/abc" }), { main: [], side: [] });
});

Deno.test("a tournament: decks with records, top 8 by standing, finished rounds as matches", () => {
  const t: TdTournament = {
    TID: "abc123", tournamentName: "Modern Open", startDate: Date.UTC(2026, 9, 18) / 1000, topCut: 8,
    standings: Array.from({ length: 40 }, (_, i) => ({ id: `p${i}`, deckObj: i < 38 ? { Mainboard: main60 } : null, wins: 9 - (i % 9), losses: i % 9, draws: 0 })),
    rounds: [{ round: 1, tables: [
      { table: 1, players: [{ id: "p0" }, { id: "p1" }], winner_id: "p0", winner_games: 2, loser_games: 1, status: "Completed" },
      { table: 2, players: [{ id: "p2" }, { id: "p3" }], winner_id: "Draw", status: "Completed" },
      { table: 3, players: [{ id: "p4" }, { id: "p5" }], winner_id: null, status: "Active" },
      { table: "Byes", players: [{ id: "p6" }], status: "Bye" },
    ] }],
  };
  const ev = parseTournament(t, "modern")!;
  assertEquals(ev.source, "topdeck");
  assertEquals(ev.on, "2026-10-18");
  assertEquals(ev.players, 40);
  assertEquals(ev.decks.length, 38, "decks without a public list are left out");
  assertEquals(ev.complete, false, "two lists missing: no conversion rates from this event");
  assertEquals(ev.decks.filter((d) => d.top8).length, 8);
  assertEquals(ev.matches, [
    { round: "1", a: "p0", b: "p1", result: "a", a_wins: 2, b_wins: 1 },
    { round: "1", a: "p2", b: "p3", result: "draw", a_wins: null, b_wins: null },
  ]);
  assertEquals(parseTournament({ ...t, standings: t.standings!.map((s) => ({ ...s, deckObj: null })) }, "modern"), null);
});

Deno.test("a real answer (scrubbed: player ids replaced, no names): 64 decks, Swiss and top 8 rounds", async () => {
  const t = JSON.parse(await Deno.readTextFile("../../testdata/insights/topdeck/pauper-64.json")) as TdTournament;
  const ev = parseTournament(t, "pauper")!;
  assertEquals(ev.players, 64);
  assertEquals(ev.decks.length, 64);
  assertEquals(ev.complete, true);
  assertEquals(ev.decks.filter((d) => d.top8).length, 8);
  assert(ev.decks.every((d) => d.main.reduce((n, [, q]) => n + q, 0) >= 60));
  assert(ev.decks.some((d) => d.side.length > 0));
  assertEquals(ev.matches.length, 177, "every finished two-player table");
  assert(ev.matches.some((m) => m.round === "Top 8"));
  assert(ev.matches.every((m) => m.a_wins != null || m.result === "draw"));
  assert(!JSON.stringify(ev).match(/[A-Za-z0-9]{20,}/), "no source ids beyond the scrubbed ones");
});
