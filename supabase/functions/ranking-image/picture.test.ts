// ranking-image (picture.ts, request.ts): the apps' Top 100 picture as SVG, for a top 100, a top 50 and a color's list,
// and the request the bot sends.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { CH, corner, CW, GAP, MAX_CARDS, MIN_WIDTH, PAD, PEEK, PER, rankingPicture, size } from "./picture.ts";
import { layoutFor, parseAsk } from "./request.ts";

const uuid = (n: number) => `c0000000-0000-0000-0000-${String(n).padStart(12, "0")}`;
const cards = (n: number) => Array.from({ length: n }, (_, i) => ({ name: `Card ${i + 1}`, cardId: uuid(i + 1), set: i === 0 ? "lea" : "mh2" }));
const art = (n: number) => new Map(cards(n).map((c) => [c.cardId, { href: "data:image/jpeg;base64,AA==" }]));

Deno.test("piles of ten, as wide as the app's for a top 100, never narrower than the header needs", () => {
  assertEquals(size(100), { width: PAD * 2 + 10 * (CW + GAP) - GAP, height: PAD + 90 + 24 + 9 * PEEK + CH + PAD, piles: 10 });
  assertEquals(size(100).width, 1870);
  assertEquals(size(50).piles, 5);
  assertEquals(size(17), { width: MIN_WIDTH, height: size(100).height, piles: 2 });
  assertEquals(size(3).height, PAD + 90 + 24 + 2 * PEEK + CH + PAD, "a short pile is a short picture");
  assertEquals(size(250).piles, MAX_CARDS / PER, "at most 100 places");
});

Deno.test("every card drawn in rank order with its badge; pile headings; the header", () => {
  const pic = rankingPicture({ title: "Ana Lind · Summer", byline: "Ranking of Lindmark Cube · Top 50 · Ranked on Table 1 · Nov 3, 2026", cards: cards(50), art: art(50) });
  assertEquals(pic.width, 960);
  assertEquals((pic.svg.match(/<image /g) ?? []).length, 50);
  for (const n of [1, 10, 11, 50]) assert(pic.svg.includes(`text-anchor="middle">${n}</text>`), `badge ${n}`);
  for (const h of ["#1–10", "#11–20", "#41–50"]) assert(pic.svg.includes(`>${h}</text>`), h);
  assert(pic.svg.includes(">Ana Lind · Summer</text>"));
  assert(pic.svg.includes(">TABLE-1.SITE</text>"));
  // Card 11 starts the second pile, at the top; card 12 peeks below it.
  assert(pic.svg.includes(`<image x="${PAD + CW + GAP}" y="${PAD + 90 + 24}"`));
  assert(pic.svg.includes(`<image x="${PAD + CW + GAP}" y="${PAD + 90 + 24 + PEEK}"`));
  // No clip paths (a layer per card in resvg, what hit the edge's CPU limit); the corners that show are painted over,
  // Alpha's rounder, as in the deck picture: a pile's first card's top corners, its last card's bottom ones.
  assert(!pic.svg.includes("clip-path") && !pic.svg.includes("<clipPath"));
  assert(pic.svg.includes(corner(PAD, PAD + 90 + 24, CW * 0.0699, 1, 1)), "Alpha's top-left corner");
  assertEquals((pic.svg.match(/<path /g) ?? []).length, 5 * 4, "four corners per pile of ten");
  const short = rankingPicture({ title: "T", byline: "B", cards: cards(3), art: art(3) });
  assert(short.svg.includes(corner(PAD + CW, PAD + 90 + 24 + 2 * PEEK + CH, CW * 0.0432, -1, -1)), "a short pile's last card's bottom-right");
});

Deno.test("a corner is the square outside its radius, swept toward the card", () => {
  assertEquals(corner(10, 20, 5, 1, 1), `<path d="M10.00 20.00H15.00A5.00 5.00 0 0 0 10.00 25.00Z" fill="#171725"/>`);
  assertEquals(corner(10, 20, 5, -1, 1), `<path d="M10.00 20.00H5.00A5.00 5.00 0 0 1 10.00 25.00Z" fill="#171725"/>`);
  assertEquals(corner(10, 20, 0, 1, 1), "", "a square-cornered printing (CED) has none");
});

Deno.test("a card without art shows its name; text is escaped; a short list pile is labelled to its end", () => {
  const list = [{ name: "Fire // Ice <&>", cardId: null, set: null }, { name: "Opt", cardId: uuid(2), set: "xln" }];
  const pic = rankingPicture({ title: "A & B", byline: "Ranking of <cube>", cards: list, art: new Map() });
  assert(pic.svg.includes(">Fire // Ice &lt;&amp;&gt;</text>"));
  assert(pic.svg.includes(">Opt</text>"), "art that couldn't be fetched shows the name too");
  assert(pic.svg.includes(">A &amp; B</text>") && pic.svg.includes(">Ranking of &lt;cube&gt;</text>"));
  assert(pic.svg.includes(">#1–2</text>"));
  assertEquals((pic.svg.match(/<image /g) ?? []).length, 0);
});

Deno.test("the request: a title, a byline and 1 to 100 cards with Oracle ids; bad printings dropped", () => {
  const ok = parseAsk({ title: "T", byline: "B", cards: [{ oracle_id: uuid(1).toUpperCase(), name: "X", card_id: "nope" }, { oracle_id: uuid(2), name: "Y", card_id: uuid(9) }] });
  assertEquals(ok?.cards, [{ oracle_id: uuid(1), name: "X", card_id: null }, { oracle_id: uuid(2), name: "Y", card_id: uuid(9) }]);
  assertEquals(parseAsk({ title: "T", byline: "B", cards: [] }), null);
  assertEquals(parseAsk({ title: "T", byline: "B", cards: Array.from({ length: 101 }, (_, i) => ({ oracle_id: uuid(i), name: "x" })) }), null);
  assertEquals(parseAsk({ title: "T", cards: [{ oracle_id: uuid(1), name: "X" }] }), null);
  assertEquals(parseAsk({ title: "T", byline: "B", cards: [{ oracle_id: "x", name: "X" }] }), null);
  assertEquals(parseAsk(null), null);
});

Deno.test("cards drawn at the small image's own 146 px, nearest-neighbour, so nothing is resampled", () => {
  for (const n of [17, 50, 100]) assertEquals(layoutFor(n), { scale: 146 / 168, art: "small", imageRendering: 1 });
  assertEquals(Math.round(CW * layoutFor(100).scale), 146);
});
