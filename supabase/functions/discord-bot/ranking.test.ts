// /ranking (ranking.ts): lists worked out from a ranking's log with the apps' engine, the picker's lines and the post.
// Logs come from ranking-brief's simulateLog, which plays a whole ranking from a known order.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { type CardFact, simulateLog } from "../ranking-brief/brief.ts";
import { COMMANDS, HELP } from "./embeds.ts";
import {
  emptyText, rankingChoice, rankingComponents, rankingEmbed, rankingImageAsk, type RankingPost, rankingTitle, rankingView, rankShow,
} from "./ranking.ts";

const id = (n: number) => `c0000000-0000-0000-0000-${String(n).padStart(12, "0")}`;
const fact = (n: number, name: string, type: string, cost: string | null, colors: string[]): CardFact =>
  ({ oracle_id: id(n), name, type_line: type, mana_cost: cost, cmc: null, colors, produced_mana: null });
// Twelve cards: four white, four blue, two red, two lands; no multicolor.
const FACTS: CardFact[] = [
  fact(1, "Swords to Plowshares", "Instant", "{W}", ["W"]), fact(2, "Ancestral Recall", "Instant", "{U}", ["U"]),
  fact(3, "Lightning Bolt", "Instant", "{R}", ["R"]), fact(4, "Strip Mine", "Land", null, []),
  fact(5, "Brainstorm", "Instant", "{U}", ["U"]), fact(6, "Balance", "Sorcery", "{1}{W}", ["W"]),
  fact(7, "Wasteland", "Land", null, []), fact(8, "Opt", "Instant", "{U}", ["U"]),
  fact(9, "Savannah Lions", "Creature — Cat", "{W}", ["W"]), fact(10, "Chain Lightning", "Sorcery", "{R}", ["R"]),
  fact(11, "Ponder", "Sorcery", "{U}", ["U"]), fact(12, "Mother of Runes", "Creature — Human Cleric", "{W}", ["W"]),
];
// Best first, as the person ranks them.
const ORDER = [2, 1, 3, 5, 6, 4, 12, 10, 8, 7, 11, 9].map(id);
const RID = "f7000000-0000-0000-0000-000000000001";
const nameOf = new Map(FACTS.map((f) => [f.oracle_id, f.name]));

function post(over: Partial<RankingPost> = {}, depth: RankingPost["depth"] = "full", top = 50): RankingPost {
  return {
    id: RID, name: "Summer", depth, top, sharing: "cube", set_key: null, by: { display_name: "Ana Lind" },
    log: simulateLog(FACTS, RID, depth, top, ORDER), baseline: FACTS.map((f) => f.oracle_id), cards: FACTS.map((f) => f.oracle_id),
    facts: FACTS.map((f) => [f.oracle_id, f.name, f.type_line, f.mana_cost, f.colors]),
    cube: { name: "Lindmark Cube", printings: { [id(2)]: "c1000000-0000-0000-0000-000000000002" } }, ...over,
  };
}

Deno.test("show: the final's top 50 or 100, a color, or the ranking's own final", () => {
  assertEquals(rankShow(undefined, 100), { job: "F", n: 100 });
  assertEquals(rankShow("50", 100), { job: "F", n: 50 });
  assertEquals(rankShow("100", 50), { job: "F", n: 100 });
  assertEquals(rankShow("W", 50), { job: "W", n: null });
  assertEquals(rankShow("L", 50), { job: "L", n: null });
  assertEquals(rankShow("F", 50), null);
  assertEquals(rankShow("X", 50), null);
});

Deno.test("a finished ranking: the final in the person's order, and each color's list", () => {
  const p = post();
  const fin = rankingView(p, { job: "F", n: 50 })!;
  assertEquals(fin.rows.map((r) => r.id), ORDER);
  assertEquals(fin.rows[0].name, "Ancestral Recall");
  assert(fin.done);
  const white = rankingView(p, { job: "W", n: null })!;
  assertEquals(white.rows.map((r) => r.name), ["Swords to Plowshares", "Balance", "Mother of Runes", "Savannah Lions"]);
  assertEquals(rankingView(p, { job: "L", n: null })!.rows.map((r) => r.name), ["Strip Mine", "Wasteland"]);
  assertEquals(rankingView(p, { job: "F", n: 5 })!.rows.map((r) => nameOf.get(r.id)),
    ["Ancestral Recall", "Swords to Plowshares", "Lightning Bolt", "Brainstorm", "Balance"]);
});

Deno.test("a top quarter: each color stops at its target", () => {
  const p = post({}, "quarter", 50);
  const blue = rankingView(p, { job: "U", n: null })!;
  assertEquals([blue.rows.map((r) => r.name), blue.target, blue.size, blue.done], [["Ancestral Recall"], 1, 4, true]);
  assertEquals(rankingEmbed(p, blue).description, "The top quarter of 4 blue cards.");
  assertEquals(rankingEmbed(p, rankingView(p, { job: "L", n: null })!).description, "The top quarter of 2 lands.");
});

Deno.test("half done: the places so far, and how far along", () => {
  const full = post();
  const p = { ...full, log: full.log.slice(0, Math.floor(full.log.length / 2)) };
  const v = rankingView(p, { job: "F", n: 50 })!;
  assert(!v.done);
  assert(v.placed < 12);
  assertEquals(v.rows.map((r) => r.id), ORDER.slice(0, v.placed), "what's placed is the top of the order");
  assertEquals(rankingEmbed(p, v).description, `${v.placed} of 12 placed so far.`);
  const white = rankingView(post({ log: [] }), { job: "W", n: null })!;
  assertEquals(emptyText(post(), "W", white), "No white cards placed yet. Rank on Table 1, then post it.");
  assertEquals(emptyText(post(), "F", rankingView(post({ log: [] }), { job: "F", n: 50 })), "Nothing's placed in this ranking's final yet. Rank on Table 1, then post it.");
});

Deno.test("a card new to the cube waits outside the lists and is counted", () => {
  const p = post({ baseline: FACTS.filter((f) => f.name !== "Opt").map((f) => f.oracle_id), log: simulateLog(FACTS.filter((f) => f.name !== "Opt"), RID, "full", 50, ORDER) });
  const v = rankingView(p, { job: "F", n: 50 })!;
  assertEquals(v.waiting, 1);
  assert(!v.rows.some((r) => r.name === "Opt"));
  assert(rankingEmbed(p, v).description!.endsWith("1 new card not placed yet."));
});

Deno.test("a color the cube doesn't have, and a top 100 of a top-50 ranking", () => {
  assertEquals(rankingView(post(), { job: "M", n: null }), null);
  assertEquals(emptyText(post(), "M", null), "Lindmark Cube has no multicolor cards.");
  assertEquals(emptyText(post({ cube: { name: "Sparse" } }), "L", null), "Sparse has no lands.");
  const v = rankingView(post(), { job: "F", n: 100 })!;
  assert(v.short);
  assertEquals(rankingEmbed(post(), v).description, "This ranking's final is a top 50.");
});

Deno.test("the post: cube and list, who ranked it, how far along, the picture and no list of cards", () => {
  const p = post();
  const e = rankingEmbed(p, rankingView(p, { job: "F", n: 50 })!);
  assertEquals(e.title, "Lindmark Cube · Top 12");
  assertEquals(e.author.name, "Ranking by Ana Lind · Summer");
  assertEquals(e.url, `https://table-1.site/library/ranking/${RID}/lists/F`);
  assertEquals(e.image, { url: "attachment://ranking.png" });
  assertEquals(e.footer.text, "Table 1 Rankings");
  assert(!("fields" in e) && !("thumbnail" in e));
  const w = rankingEmbed(p, rankingView(p, { job: "W", n: null })!);
  assertEquals([w.title, w.description], ["Lindmark Cube · White", "All 4 white cards."]);
  const set = rankingEmbed({ ...p, set_key: "FRA", cube: { name: "Foundations Remix" } }, rankingView(p, { job: "F", n: 50 })!);
  assertEquals([set.title, set.footer.text], ["Foundations Remix · Top 12", "Table 1 Rankings · Limited"]);
});

Deno.test("the picture asked for: the apps' title and byline, the cards in order in the cube's printings", () => {
  const day = new Date("2026-11-03T20:00:00Z");
  const p = post();
  const fin = rankingImageAsk(p, rankingView(p, { job: "F", n: 50 })!, day);
  assertEquals(fin.title, "Ana Lind · Summer");
  assertEquals(fin.byline, "Ranking of Lindmark Cube · Top 12 · Ranked on Table 1 · Nov 3, 2026");
  assertEquals(fin.cards.map((c) => c.oracle_id), ORDER);
  assertEquals(fin.cards[0], { oracle_id: id(2), name: "Ancestral Recall", card_id: "c1000000-0000-0000-0000-000000000002" });
  assertEquals(fin.cards[1].card_id, null, "no printing named: ranking-image draws the usual one");
  const white = rankingImageAsk(p, rankingView(p, { job: "W", n: null })!, day);
  assertEquals([white.byline, white.cards.length], ["Ranking of Lindmark Cube · White · Ranked on Table 1 · Nov 3, 2026", 4]);
  const half = { ...p, log: p.log.slice(0, Math.floor(p.log.length / 2)), name: "My ranking" };
  const v = rankingView(half, { job: "F", n: 50 })!;
  const partial = rankingImageAsk(half, v, day);
  assertEquals(partial.title, "Ana Lind");
  assertEquals(partial.byline, `Ranking of Lindmark Cube · Top ${v.placed} · ${v.placed} of 12 ranked so far · Ranked on Table 1 · Nov 3, 2026`);
});

Deno.test("titles and the picker: the label after the person; My ranking isn't one", () => {
  assertEquals(rankingTitle("Ana Lind", "My ranking"), "Ana Lind");
  assertEquals(rankingTitle("Ana Lind", "  "), "Ana Lind");
  assertEquals(rankingTitle(null, "Power only"), "Someone · Power only");
  assertEquals(rankingChoice({ id: RID, subject: "Lindmark Cube", kind: "cube", set: null, name: "My ranking", top: 100, ranked: 87 }), "Lindmark Cube · 87/100 ranked");
  assertEquals(rankingChoice({ id: RID, subject: "Foundations Remix", kind: "set", set: "FRA", name: "Draft night", top: 50, ranked: 50 }),
    "Foundations Remix (FRA) · Draft night · 50/50 ranked");
});

Deno.test("Open in Table 1 only for a shared ranking, on the list posted", () => {
  assertEquals(rankingComponents(post({ sharing: "private" }), "F"), []);
  assertEquals(rankingComponents(post(), "W")[0].components[0].url, `https://table-1.site/library/ranking/${RID}/lists/W`);
});

Deno.test("/ranking is registered with its picker and the show choices, and in /help", () => {
  const c = (COMMANDS as { name: string; options: { name: string; autocomplete?: boolean; choices?: { value: string }[] }[] }[])
    .find((x) => x.name === "ranking")!;
  assertEquals(c.options.map((o) => o.name), ["ranking", "show"]);
  assert(c.options[0].autocomplete);
  assertEquals(c.options[1].choices!.map((x) => x.value), ["50", "100", "W", "U", "B", "R", "G", "M", "C", "L"]);
  assert(c.options[1].choices!.every((x) => rankShow(x.value, 50) != null));
  assert(HELP.some((h) => h.command === "/ranking"));
});
