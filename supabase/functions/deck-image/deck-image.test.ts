import { assert, assertEquals } from "jsr:@std/assert@1";
import { fit, type Line, ordered, plan, typeGroup } from "./layout.ts";
import { artSize, clip, picture } from "./svg.ts";

const cases = JSON.parse(await Deno.readTextFile(new URL("../../../testdata/deck-image/cases.json", import.meta.url)));

Deno.test("card sizes match the shared cases (the same numbers as iOS, web and Android)", () => {
  for (const c of cases.fit as { main: number; side: number; cols: number; cw: number; step: number; height: number }[]) {
    const f = fit(c.main, c.side);
    assertEquals([f.cols, f.cw, Number(f.step.toFixed(4)), f.height], [c.cols, c.cw, c.step, c.height], `${c.main}/${c.side}`);
  }
});

const line = (o: Partial<Line> & { name: string }): Line => ({
  card_id: `${o.name.toLowerCase().replace(/[^a-z]/g, "")}-0000-4000-8000-000000000001`, oracle_id: `o-${o.name}`, board: "main", qty: 1,
  finish: "nonfoil", type_line: "Creature", cmc: 1, set: "m10", image_ts: 1700000000, ...o,
});

Deno.test("the plan: commander first, type groups in order, by mana value then name, sideboard apart, Considering off", () => {
  const p = plan([
    line({ name: "Opt", type_line: "Instant", cmc: 1 }),
    line({ name: "Counterspell", type_line: "Instant", cmc: 2, qty: 4 }),
    line({ name: "Island", type_line: "Basic Land — Island", cmc: 0, qty: 20 }),
    line({ name: "Snapcaster Mage", type_line: "Creature — Human Wizard", cmc: 2 }),
    line({ name: "Dreadmaw", type_line: "Creature — Dinosaur", cmc: 6, board: "side", qty: 2 }),
    line({ name: "Brainstorm", type_line: "Instant", cmc: 1, board: "maybe" }),
    line({ name: "Grist", type_line: "Legendary Planeswalker — Grist // Creature", cmc: 3, board: "commander" }),
    line({ name: "Counterspell", type_line: "Instant", cmc: 2, qty: 1, card_id: "counterspell-0000-4000-8000-000000000002", set: "sta", finish: "foil" }),
  ]);
  assertEquals(p.main.map((g) => g.title), ["Commander", "Creatures", "Instants", "Lands"]);
  assertEquals(p.main[2].cards.map((c) => `${c.name}×${c.qty}`), ["Opt×1", "Counterspell×5"]);
  assertEquals(p.main[2].cards[1].set, "m10", "the most-held printing leads");
  assertEquals(p.side.map((c) => c.name), ["Dreadmaw"]);
  assertEquals(ordered(p).length, 5);
  assert(!JSON.stringify(p).includes("Brainstorm"));
  assertEquals(typeGroup("Artifact Creature — Golem"), "Creatures");
  assertEquals(typeGroup("Battle — Siege"), "Battles");
});

Deno.test("the picture: header, a tile per card with its count, the sideboard divider, no network", () => {
  const lines = [
    line({ name: "Lightning Bolt", type_line: "Instant", qty: 4 }),
    line({ name: "Monastery Swiftspear", type_line: "Creature — Human Monk", qty: 4 }),
    line({ name: "Mountain", type_line: "Basic Land — Mountain", cmc: 0, qty: 20 }),
    line({ name: "Smash to Smithereens", type_line: "Instant", cmc: 2, board: "side", qty: 3 }),
    line({ name: "Tormod's Crypt <foil>", type_line: "Artifact", cmc: 0, board: "side", qty: 2, finish: "foil" }),
  ];
  const p = plan(lines);
  const art = new Map([[ordered(p)[0].cardId, { href: "data:image/jpeg;base64,/9j/4AAQ" }]]);
  const pic = picture({ name: "Burn & Co", format: "modern", player: "Ana", plan: p, art, date: new Date("2026-11-07T12:00:00Z") });
  assertEquals([pic.width, pic.height], [1200, 675]);
  assert(pic.svg.startsWith("<svg "));
  assert(pic.svg.includes(">Burn &amp; Co<"), "the name is escaped");
  assert(pic.svg.includes(">By Ana<"));
  assert(pic.svg.includes("Nov 7, 2026 · Format: Modern · Deck: 28 cards · Sideboard: 5 cards"));
  assert(pic.svg.includes(">TABLE-1.SITE<"));
  assert(pic.svg.includes("SIDEBOARD"));
  assertEquals((pic.svg.match(/<image /g) ?? []).length, 1, "only fetched art is drawn as an image");
  assert(pic.svg.includes("Tormod&#39;s Crypt &lt;foil&gt;") || pic.svg.includes("Tormod's Crypt &lt;foil&gt;"), "a missing image shows the escaped name");
  for (const n of ["4", "20", "3", "2"]) assert(pic.svg.includes(`text-anchor="middle">${n}</text>`), `badge ${n}`);
  assert(pic.svg.includes('fill="url(#sheen)"'), "a foil gets the sheen");
  assert(!pic.svg.includes("scryfall.io") && !pic.svg.includes("https://"), "nothing in the picture points at the network");
});

Deno.test("a 100-card deck grows taller; clip and art size", () => {
  const lines = Array.from({ length: 100 }, (_, i) => line({ name: `Card ${String(i).padStart(3, "0")}`, cmc: i % 7 }));
  const pic = picture({ name: "Big", format: "commander", player: null, plan: plan(lines), art: new Map() });
  assertEquals(pic.height, 1131);
  assert(!pic.svg.includes(">By "));
  assertEquals(clip("Lightning Bolt", 11, 60), "Lightnin…");
  assertEquals(clip("Opt", 11, 60), "Opt");
  assertEquals([artSize(109 * 1600 / 1200), artSize(72 * 1600 / 1200)], ["small", "small"]);
  assertEquals(artSize(172 * 1600 / 1200), "normal");
});
