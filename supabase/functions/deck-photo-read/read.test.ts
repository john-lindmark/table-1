// deno test --allow-read=../../testdata deck-photo-read/
// The matching rules on what the reader actually said about the 24 deck photos posted up to 2026-11-13
// (testdata/deck-photo-lists: the three card pools, each photo's cards as reported, the catalog's answers).
import { assert, assertEquals } from "jsr:@std/assert@1";
import { ask, deckSize, entries, indexPool, inPool, isBasic, norm, score, seen, similar, stepDone, stepPool, toAsk, totals, type Named, type Pool, type Seen } from "./read.ts";

const T = new URL("../../../testdata/deck-photo-lists/", import.meta.url);
const pools = JSON.parse(Deno.readTextFileSync(new URL("pools.json", T))) as Record<string, { kind: Pool["kind"]; label: string; names: string[] }>;
const catalog = new Set((JSON.parse(Deno.readTextFileSync(new URL("catalog.json", T))) as string[]).map(norm));
const BASIC = ["Plains", "Island", "Swamp", "Mountain", "Forest", "Wastes"];

const poolOf = (key: string | null): Pool =>
  key ? { kind: pools[key].kind, label: pools[key].label, cards: pools[key].names.map((n, i) => [n, `${key}-${i}`]) } : { kind: "none", label: "Draft", cards: [] };
/** The catalog as deck_photo_read_names answers: every pool, the outside names checked on live, the basics. */
function names(qs: string[]): Named[] {
  const known = new Map<string, string>();
  for (const k of Object.keys(pools)) for (const n of pools[k].names) { known.set(norm(n), n); known.set(norm(n.split(" // ")[0]), n); }
  for (const b of BASIC) known.set(norm(b), b);
  return qs.map((q) => {
    const hit = known.get(norm(q)) ?? (catalog.has(norm(q)) ? q : null);
    return { q, name: hit, card_id: hit ? `cat-${norm(hit)}` : null, exact: hit ? true : null };
  });
}
interface ReadFile { photo_id: string; pool: string | null; event_type: string; format_label: string; cards: Seen[] }
const reads = [...Deno.readDirSync(new URL("reads/", T))].map((f) => f.name).sort()
  .map((f) => JSON.parse(Deno.readTextFileSync(new URL(`reads/${f}`, T))) as ReadFile);

Deno.test("names compare without accents, case or punctuation", () => {
  assertEquals(norm("Lórien Revealed"), "lorien revealed");
  assertEquals(norm("Urza's Saga"), "urzas saga");
  assertEquals(norm("Fire // Ice"), "fire ice");
  assert(isBasic("Snow-Covered Island") && isBasic("forest") && !isBasic("Forest Bear"));
  assert(similar("lightning bolt", "lightning bolt") === 1 && similar("lightning bolt", "lightning helix") < 0.72);
});

Deno.test("the pool takes an exact name, a split card's first half, and one clearly closest near miss", () => {
  const ix = indexPool({ kind: "cube", label: "Cube", cards: [["Fire // Ice", "a"], ["Lightning Bolt", "b"], ["Lightning Helix", "c"], ["Chain Lightning", "d"]] });
  assertEquals(inPool(ix, "fire")?.card[1], "a");
  assertEquals(inPool(ix, "Lightning Bolt"), { card: ["Lightning Bolt", "b"], exact: true });
  assertEquals(inPool(ix, "Lightnlng Bolt"), { card: ["Lightning Bolt", "b"], exact: false });
  assertEquals(inPool(ix, "Lightning"), null); // close to three cards: nobody wins
  assertEquals(inPool(ix, "Counterspell"), null);
});

Deno.test("every posted photo: each line names a pool card or a catalog card, apart from three titles nobody could read", () => {
  assertEquals(reads.length, 24);
  const unmatched: string[] = [];
  let lines = 0;
  for (const r of reads) {
    const ix = indexPool(poolOf(r.pool));
    const list = entries(seen({ cards: r.cards }).cards, ix, names(toAsk(r.cards, ix)));
    lines += list.length;
    for (const e of list) {
      if (!e.card_id) { unmatched.push(e.name); assert(!e.sure, `${e.name} unmatched lines are always to check`); }
      assert(e.qty >= 1 && ["main", "side", "out"].includes(e.board));
    }
    // One line per card and board.
    assertEquals(new Set(list.map((e) => `${e.card_id ?? e.name}|${e.board}`)).size, list.length, r.photo_id);
    // Limited decks: the main deck lands within a few cards of 40 on every photo that shows the whole deck.
    const t = totals(list);
    assert(t.main >= 32 && t.main <= 41, `${r.photo_id} main ${t.main}`);
  }
  assertEquals(unmatched.sort(), ["Room of", "Rurk Thar, Magecrusher", "Unknown"]);
  assert(lines > 600);
});

Deno.test("a whole title outside the pool is kept as read: Mystery Booster 2's reprints are filed under another set", () => {
  const r = reads.find((x) => x.pool === "mb2")!;
  const ix = indexPool(poolOf("mb2"));
  const list = entries(r.cards, ix, names(toAsk(r.cards, ix)));
  const wurm = list.find((e) => e.name === "Arrogant Wurm")!;
  assertEquals([wurm.card_id, wurm.sure], ["cat-arrogant wurm", true]);
  assertEquals(totals(list).main, 40);
});

Deno.test("a catalog card read whole beats a near miss in the pool; a near miss alone is taken, to check", () => {
  const ix = indexPool({ kind: "set", label: "Set", cards: [["Stingcaster Mage", "p1"], ["Goblin Guide", "p2"]] });
  const cat: Named[] = [{ q: "Stingcaster Sage", name: "Stingcaster Sage", card_id: "c1", exact: true }];
  assertEquals(entries([{ name: "Stingcaster Sage", qty: 1, board: "main", sure: true }], ix, cat)[0].card_id, "c1");
  const near = entries([{ name: "Gobln Guide", qty: 2, board: "main", sure: true }], ix, [{ q: "Gobln Guide", name: null, card_id: null, exact: null }])[0];
  assertEquals([near.card_id, near.name, near.sure, near.read], ["p2", "Goblin Guide", false, 'read as "Gobln Guide"']);
});

Deno.test("the same card twice on a board is one line; out goes last and is never counted", () => {
  const ix = indexPool({ kind: "cube", label: "Cube", cards: [["Island", "i"], ["Mana Drain", "m"], ["Mine Collapse", "x"]] });
  const list = entries([
    { name: "Mine Collapse", qty: 1, board: "out", sure: false, read: "sideways, off the mat" },
    { name: "Island", qty: 4, board: "main", sure: true },
    { name: "Mana Drain", qty: 1, board: "main", sure: true },
    { name: "island", qty: 3, board: "main", sure: false, read: "pile of about 3" },
  ], ix, []);
  assertEquals(list.map((e) => [e.name, e.qty, e.board, e.sure]), [["Island", 7, "main", false], ["Mana Drain", 1, "main", true], ["Mine Collapse", 1, "out", false]]);
  assertEquals(totals(list), { cards: 8, main: 8, check: 1 });
  assertEquals(stepDone(list), "Read 8 cards: 1 to check");
});

Deno.test("the model's answer is made safe", () => {
  const s = seen({ cards: [{ name: " Bolt ", qty: 400, board: "weird", sure: "yes" }, { name: "", qty: 1 }, null, { name: "X", qty: -2, board: "out", sure: false, read: "r" }], notes: 5 });
  assertEquals(s.cards, [{ name: "Bolt", qty: 99, board: "main", sure: true }, { name: "X", qty: 1, board: "out", sure: false, read: "r" }]);
  assertEquals(seen(null), { cards: [], notes: "" });
});

Deno.test("what the model is told: the event, the deck size, the pool by name", () => {
  const e = { name: "Friday draft", event_type: "limited", format: "draft", format_label: "Draft · Reality Fracture" };
  const text = ask(e, poolOf("fra"));
  assert(text.includes("Friday draft (Draft · Reality Fracture)") && text.includes("exactly 40 cards") && text.includes(`Card pool (Reality Fracture, ${pools.fra.names.length} cards)`));
  assert(ask({ ...e, event_type: "constructed", format: "modern" }, poolOf(null)).includes("No card pool is known"));
  assertEquals([deckSize(e), deckSize({ ...e, event_type: "constructed", format: "modern" }), deckSize({ ...e, event_type: "constructed", format: "commander" }), deckSize({ ...e, event_type: null })], [40, 60, 100, null]);
  assertEquals(stepPool(poolOf("lindmark")), `Reading against Lindmark Cube: ${pools.lindmark.names.length} cards`);
  assertEquals(stepPool(poolOf(null)), "Reading every title: no card pool for this event");
});

Deno.test("scoring a read against a reference list", () => {
  const want = [{ name: "Island", qty: 8, board: "main" }, { name: "Mana Drain", qty: 1, board: "main" }, { name: "Stray", qty: 1, board: "out" }];
  const got = [{ name: "island", qty: 7, board: "main" }, { name: "Mana Drain", qty: 1, board: "main" }, { name: "Counterspell", qty: 1, board: "main" }];
  assertEquals(score(got, want), { read: 9, want: 9, both: 8, recall: 8 / 9, precision: 8 / 9 });
});
