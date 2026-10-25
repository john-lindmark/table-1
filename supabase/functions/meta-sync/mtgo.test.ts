import { assert, assertEquals } from "jsr:@std/assert@1";
import { indexSlugs, pageData, parseEvent, slugInfo } from "./mtgo.ts";

const T = "../../testdata/insights/mtgo";
const json = async (f: string) => JSON.parse(await Deno.readTextFile(`${T}/${f}`));

Deno.test("slugs: format, kind, date and an id that stays unique for daily leagues", () => {
  assertEquals(slugInfo("modern-challenge-32-2026-10-2412856973"),
    { format: "modern", kind: "challenge", on: "2026-10-24", id: "12856973-20261024", words: "challenge-32" });
  assertEquals(slugInfo("modern-league-2026-10-0111161")?.id, "11161-20261001");
  assertEquals(slugInfo("modern-league-2026-10-0211161")?.id, "11161-20261002");
  assertEquals(slugInfo("modern-showcase-challenge-2026-10-1212856566")?.kind, "showcase");
  assertEquals(slugInfo("modern-rc-super-qualifier-2026-10-1812856700")?.kind, "qualifier");
  assertEquals(slugInfo("standard-championship-week-finals-2026-10-1012856100")?.kind, "championship");
  assertEquals(slugInfo("standard-challenge-16-special-2026-10-1112856200")?.kind, "challenge");
  assertEquals(slugInfo("limited-rc-super-qualifier-2026-10-1812856701"), null, "Limited isn't read");
  assertEquals(slugInfo("duel-commander-league-2026-10-0111169"), null);
  assertEquals(slugInfo("not-a-slug"), null);
});

Deno.test("month index: event slugs once each, in page order", async () => {
  const slugs = indexSlugs(await Deno.readTextFile(`${T}/index-2026-10.html`));
  assertEquals(slugs.length, 40);
  assertEquals(slugs[0], "standard-league-2026-10-2511129");
  assertEquals(new Set(slugs).size, slugs.length);
});

Deno.test("page data: the embedded object, or null", async () => {
  const d = pageData(await Deno.readTextFile(`${T}/modern-league-2026-10-0111161.html`));
  assert(d);
  assertEquals((d.decklists as unknown[]).length, 3);
  assertEquals(pageData("<html>no data</html>"), null);
  assertEquals(pageData("window.MTGO.decklists.data = {broken;\n"), null);
});

Deno.test("a Challenge: decks with ranks, records, top 8 and the bracket as matches", async () => {
  const ev = parseEvent("modern-challenge-64-2026-10-2112857053", await json("modern-challenge-64-2026-10-2112857053.json"))!;
  assertEquals(ev.source, "mtgo");
  assertEquals(ev.kind, "challenge");
  assertEquals(ev.on, "2026-10-21");
  assert(ev.players! >= 64, "player count from the page, not the decks published");
  assertEquals(ev.decks.length, 32);
  assertEquals(ev.decks.filter((d) => d.top8).length, 8);
  assertEquals(ev.decks.filter((d) => d.rank === 1).length, 1);
  for (const d of ev.decks) {
    assert(d.main.reduce((n, [, q]) => n + q, 0) >= 60, "a full main deck");
    assert(d.side.reduce((n, [, q]) => n + q, 0) <= 15);
    assert(/^\d+$/.test(d.player), "players are login ids, never names");
  }
  assertEquals(ev.matches.length, 7);
  assertEquals(ev.matches.filter((m) => m.round === "QF").length, 4);
  assertEquals(ev.matches.filter((m) => m.round === "F").length, 1);
  const finalist = new Set(ev.decks.filter((d) => d.rank! <= 2).map((d) => d.player));
  const final = ev.matches.find((m) => m.round === "F")!;
  assert(finalist.has(final.a) && finalist.has(final.b));
  assert(!JSON.stringify(ev).includes("\"P1\""), "fixture names never reach the event");
});

Deno.test("a League: no ranks, no top 8, no matches", async () => {
  const d = pageData(await Deno.readTextFile(`${T}/modern-league-2026-10-0111161.html`))!;
  const ev = parseEvent("modern-league-2026-10-0111161", d)!;
  assertEquals(ev.kind, "league");
  assertEquals(ev.players, null);
  assertEquals(ev.decks.length, 3);
  assert(ev.decks.every((x) => !x.top8 && x.rank == null));
  assertEquals(ev.matches, []);
});

Deno.test("copies of a card split across lines are added up", () => {
  const ev = parseEvent("pauper-challenge-16-2026-10-1012856164", {
    decklists: [{ loginid: 1, main_deck: [{ qty: "2", card_attributes: { card_name: "Island" } }, { qty: "3", card_attributes: { card_name: "Island" } }], sideboard_deck: [] }],
  })!;
  assertEquals(ev.decks[0].main, [["Island", 5]]);
  assertEquals(parseEvent("pauper-challenge-16-2026-10-1012856164", { decklists: [] }), null);
});
