// The brief's data and prompt, on the shared cube-ranking cases (testdata/cube-ranking/cases.json). No network:
// the Claude call itself is only in index.ts.
import { assert, assertEquals, assertMatch, assertNotEquals } from "jsr:@std/assert@1";
import { cleanBrief, colorJob, inputHash, prompt, sides, simulateLog, type CardFact, type RankingIn } from "./brief.ts";
import type { RankJob, RankScreen } from "./cubeRanking.ts";

const cases = JSON.parse(await Deno.readTextFile(new URL("../../../testdata/cube-ranking/cases.json", import.meta.url)));
const COLORS: Record<string, { colors: string[]; type: string; cost: string }> = {
  W: { colors: ["W"], type: "Creature — Human", cost: "{W}" }, U: { colors: ["U"], type: "Instant", cost: "{1}{U}" },
  B: { colors: ["B"], type: "Sorcery", cost: "{B}" }, R: { colors: ["R"], type: "Instant", cost: "{R}" },
  G: { colors: ["G"], type: "Creature — Elf", cost: "{G}" }, M: { colors: ["W", "U"], type: "Creature — Spirit", cost: "{W}{U}" },
  C: { colors: [], type: "Artifact", cost: "{2}" }, L: { colors: [], type: "Land", cost: "" },
};
const facts: CardFact[] = (cases.cube.cards as string[]).map((id, i) => {
  const c = COLORS[cases.cube.category[id]];
  return { oracle_id: id, name: `Card ${i}`, type_line: c.type, mana_cost: c.cost, cmc: c.cost ? 1 + (i % 4) : 0, colors: c.colors,
           produced_mana: c.type === "Land" ? (i % 2 ? "WU" : "W") : null };
});
const run = (k: number, by: string): RankingIn => ({
  id: cases.runs[k].id, rev: 3, depth: cases.runs[k].depth, top: cases.runs[k].top, name: `Run ${k}`, by,
  log: cases.runs[k].steps.map((s: { s: RankJob; answer: string[] }): RankScreen => ({ s: s.s, o: s.answer })),
});
const a = run(0, "Ana"), b = run(1, "Ben");

Deno.test("colors follow the cube's Group by color", () => {
  const f = (type_line: string, colors: string[], mana_cost = ""): CardFact =>
    ({ oracle_id: "x", name: "x", type_line, mana_cost, cmc: 1, colors, produced_mana: null });
  assertEquals(colorJob(f("Basic Land — Mountain", [])), "L");
  assertEquals(colorJob(f("Land Creature — Forest Dryad", ["G"])), "G");
  assertEquals(colorJob(f("Instant", ["R", "W"])), "M");
  assertEquals(colorJob(f("Artifact Creature — Golem", [])), "C");
  assertEquals(colorJob(f("Sorcery", [], "{U}")), "U");
  assertEquals(colorJob(f("Legendary Creature — Cat Warrior // Legendary Planeswalker — Ajani", ["W"])), "W");
});

Deno.test("both lists come from the logs with the shared engine", () => {
  for (const list of ["F", "W", "L"] as RankJob[]) {
    const { a: sa, b: sb, cmp } = sides(facts, a, b, list);
    assertEquals([...sa.places.keys()], cases.runs[0].summary[list].top, list);
    assertEquals([...sb.places.keys()], cases.runs[1].summary[list].top, list);
    assertEquals(cmp.compared, cases.compare[list].compared, list);
  }
});

Deno.test("the prompt names both people and the list, and lists every card either placed", () => {
  const { text, compared } = prompt(facts, a, b, "F", "Test cube");
  assertEquals(compared, cases.compare.F.compared);
  assertMatch(text, /the top 20 across the whole cube/);
  assertMatch(text, /"who":"Ana"/);
  assertMatch(text, /"who":"Ben"/);
  const union = new Set([...cases.runs[0].summary.F.top, ...cases.runs[1].summary.F.top]);
  const rows = text.split("\n").filter((l) => /^Card \d+ \|/.test(l));
  assertEquals(rows.length, union.size, "a top 20 is all within the first 50 places");
  assert(rows.every((r) => / \| Ana (#\d+|below its top \d+|not placed yet) \| Ben /.test(r)), rows[0]);
  const color = prompt(facts, a, b, "W", "Test cube").text;
  assertMatch(color, /White \(the cube's white cards\)/);
  assertMatch(color, /"sorts":"only the top half"/);
});

Deno.test("a long top 100 keeps only each list's first 50 places and the biggest differences", () => {
  const many: CardFact[] = Array.from({ length: 240 }, (_, i) => ({
    oracle_id: `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`, name: `Card ${i}`, type_line: "Instant", mana_cost: "{U}",
    cmc: 1, colors: ["U"], produced_mana: null,
  }));
  const ids = many.map((f) => f.oracle_id);
  const order = (salt: number) => ids.slice().sort((x, y) => ((Number(x.slice(-4)) * salt) % 241) - ((Number(y.slice(-4)) * salt) % 241));
  const full = (id: string, salt: number): RankingIn => {
    // A log that orders every card: consecutive pairs of a fixed order (a valid, if slow, way to rank).
    const o = order(salt);
    return { id, rev: 1, depth: "full", top: 100, name: id, by: id === a.id ? "Ana" : "Ben",
             log: o.slice(1).map((c, i): RankScreen => ({ s: "F", o: [o[i], c] })) };
  };
  const { text } = prompt(many, full(a.id, 7), full(b.id, 13), "F", "Big cube");
  const rows = text.split("\n").filter((l) => /^Card \d+ \|/.test(l));
  assert(rows.length <= 110, `${rows.length} rows: at most both top 50s and the 10 biggest differences`);
  const early = (r: string) => /(Ana|Ben) #([1-9]|[1-4]\d|50) /.test(r + " ");
  assert(rows.filter((r) => !early(r)).length <= 10, "only the biggest differences come from past place 50");
  assertMatch(text, /in their top 50, and the biggest differences/);
});

Deno.test("the brief is one paragraph of at most five sentences", () => {
  assertEquals(cleanBrief({ brief: "  Both love Bolt.\n\nAna drafts red. Ben drafts blue. They agree on fixing. Ana likes aggro. Ben likes control. Extra." }),
               "Both love Bolt. Ana drafts red. Ben drafts blue. They agree on fixing. Ana likes aggro.");
  assertEquals(cleanBrief({ brief: "" }), null);
  assertEquals(cleanBrief({ nope: 1 }), null);
  assertEquals(cleanBrief(null), null);
});

Deno.test("the cache key changes with either ranking's rev, the list or the cube's cards", async () => {
  const cards = facts.map((f) => f.oracle_id);
  const k = await inputHash(a, b, "F", cards);
  assertEquals(k, await inputHash(a, b, "F", [...cards].reverse()));
  assertNotEquals(k, await inputHash({ ...a, rev: 4 }, b, "F", cards));
  assertNotEquals(k, await inputHash(a, { ...b, rev: 9 }, "F", cards));
  assertNotEquals(k, await inputHash(a, b, "W", cards));
  assertNotEquals(k, await inputHash(a, b, "F", cards.slice(1)));
  assertNotEquals(k, await inputHash(b, a, "F", cards));
});

Deno.test("eval mode plays a whole ranking from a person's order of the cards", () => {
  const order = facts.map((f) => f.oracle_id).reverse();
  const log = simulateLog(facts, a.id, "half", 20, order);
  const st = sides(facts, { ...a, log }, { ...b }, "F").a;
  // The simulated ranker puts the cards in exactly their order: the top 20 of the final is the first 20 of it.
  assertEquals([...st.places.keys()], order.slice(0, 20));
});
