// Round trip for deck and cube export (contract/lists-2026-10-15.md, Export): every file in testdata/list-export
// is what all three clients write for lists.json, and must read back here as the same lines. The expected lines are
// worked out from lists.json by each format's rules, not by the exporters' code.
import { assertEquals } from "jsr:@std/assert@1";
import { type Line, parseList } from "./parse.ts";

const dir = new URL("../../../testdata/list-export/", import.meta.url);
const read = (f: string) => Deno.readTextFileSync(new URL(f, dir));
type Entry = [string, Line["board"], number, ("foil" | "etched")?];
interface Card { name: string; set: string; cn: string }
const fixture = JSON.parse(read("lists.json")) as {
  cards: Record<string, Card>;
  deck: { entries: Entry[] };
  cube: { entries: Entry[] };
};
// Arena, Moxfield and Cube Cobra name double-faced and adventure cards by their front face; split cards keep both.
const FRONT: Record<string, string> = {
  "Delver of Secrets // Insectile Aberration": "Delver of Secrets",
  "Bonecrusher Giant // Stomp": "Bonecrusher Giant",
};
const exportName = (id: string) => FRONT[fixture.cards[id].name] ?? fixture.cards[id].name;

/** Sums lines with the same key; order-free comparison. */
function merge(lines: Line[]): Line[] {
  const out = new Map<string, Line>();
  for (const l of lines) {
    const k = JSON.stringify([l.board, l.name, l.set, l.cn, l.finish]);
    const had = out.get(k);
    out.set(k, had ? { ...had, qty: had.qty + l.qty } : { ...l });
  }
  return [...out.values()].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
}
const clean = (l: Line): Line => JSON.parse(JSON.stringify(l));
const parsed = (file: string) => merge(parseList(read(file)).entries.map(clean));
const lines = (entries: Entry[], f: (e: Entry) => Line | null) => merge(entries.map(f).filter((l): l is Line => !!l).map(clean));

Deno.test("Arena: printings and sections, no finishes, no Considering", () => {
  assertEquals(parsed("deck.arena.txt"), lines(fixture.deck.entries, ([id, board, qty]) =>
    board === "maybe" ? null : { qty, board, name: exportName(id), set: fixture.cards[id].set, cn: fixture.cards[id].cn }));
});

Deno.test("Moxfield: printings, finishes and every section", () => {
  assertEquals(parsed("deck.moxfield.txt"), lines(fixture.deck.entries, ([id, board, qty, finish]) =>
    ({ qty, board, name: exportName(id), set: fixture.cards[id].set, cn: fixture.cards[id].cn, finish })));
});

Deno.test("MTGO: main, then the sideboard (the commander goes there), names only", () => {
  assertEquals(parsed("deck.mtgo.txt"), lines(fixture.deck.entries, ([id, board, qty]) =>
    board === "maybe" ? null : { qty, board: board === "main" ? "main" : "side", name: exportName(id) }));
});

Deno.test("Plain text: names and sections", () => {
  assertEquals(parsed("deck.text.txt"), lines(fixture.deck.entries, ([id, board, qty]) => ({ qty, board, name: exportName(id) })));
  assertEquals(parsed("cube.text.txt"), lines(fixture.cube.entries, ([id, board, qty]) => ({ qty, board, name: exportName(id) })));
});

Deno.test("Cube Cobra CSV: one row per copy with printing, finish and board", () => {
  assertEquals(parsed("cube.cubecobra.csv"), lines(fixture.cube.entries, ([id, board, qty, finish]) =>
    ({ qty, board, name: exportName(id), set: fixture.cards[id].set, cn: fixture.cards[id].cn, finish })));
  // One row per copy, as Cube Cobra lists them.
  assertEquals(parseList(read("cube.cubecobra.csv")).entries.filter((l) => l.name === "Lightning Bolt").map((l) => l.qty), [1, 1]);
});

Deno.test("CSV detection leaves decklists alone and reads other card CSVs", () => {
  assertEquals(parseList("Name My deck\n4 Lightning Bolt\n").entries, [{ qty: 4, board: "main", name: "Lightning Bolt", set: undefined, cn: undefined, finish: undefined }]);
  const mox = parseList('"Count","Name","Edition","Foil","Collector Number"\r\n"2","Fire // Ice","mh2","etched","290"\r\n"1","Opt","xln","","65"\r\n');
  assertEquals(mox.entries.map(clean), [
    { qty: 2, board: "main", name: "Fire // Ice", set: "mh2", cn: "290", finish: "etched" },
    { qty: 1, board: "main", name: "Opt", set: "xln", cn: "65" },
  ]);
  // Older Cube Cobra exports have no board column: maybeboard decides.
  const old = parseList("name,Set,Collector Number,Finish,maybeboard\nOpt,XLN,65,Non-foil,true\n");
  assertEquals(old.entries.map(clean), [{ qty: 1, board: "maybe", name: "Opt", set: "xln", cn: "65" }]);
});

Deno.test("parsed.json is what the parser reads from each file (the clients resolve it back to the lists)", () => {
  const want = JSON.parse(read("parsed.json")) as Record<string, Line[]>;
  for (const [file, lines] of Object.entries(want)) assertEquals(parseList(read(file)).entries.map(clean), lines, file);
});
