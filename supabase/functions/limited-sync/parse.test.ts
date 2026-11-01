// limited-sync's parser on real 17Lands rows (testdata/insights/limited, made by make_cases.py with a csv-module
// reference): the same sums whether a file is read whole or in small slices with checkpoints, across gzip members.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { inflateMembers, startAt } from "./members.ts";
import { headerColumns, Lines, pairOf, Rows, type Acc } from "./parse.ts";

const T = "../../testdata/insights/limited";
const cases = JSON.parse(await Deno.readTextFile(`${T}/cases.json`)) as { released: string; game_rows: number; draft_rows: number; cards: number; expect: Record<string, [number, number]> };
const released = Date.parse(cases.released);

/** Reads a whole file in slices of `slice` compressed bytes (reserve must exceed the largest deflate block: the
 *  fixtures have a block per 2000 input bytes), carrying the checkpoint, window and partial line the
 *  way limited_runs stores them between requests. */
function read(file: Uint8Array, kind: "game" | "draft", slice: number, reserve: number) {
  let bit: number | null = null, win = new Uint8Array(0), carry = new Uint8Array(0), header: string[] | null = null, steps = 0, rows = 0;
  const total: Acc = new Map();
  for (;;) {
    const base = bit == null ? 0 : Math.floor(bit / 8);
    const data = file.subarray(base, base + slice);
    let r: Rows | null = header ? new Rows({ kind, cols: header }, released) : null;
    const lines = new Lines(carry, (b) => {
      if (!r) { header = headerColumns(new TextDecoder().decode(b)); r = new Rows({ kind, cols: header }, released); } else r.line(b);
    });
    const { checkpoint, done } = inflateMembers(data, base, file.length, startAt(data, base, bit, win), reserve, 64 << 20, (o) => lines.push(o));
    if (done) lines.end();
    const rr = r as Rows | null;
    for (const [k, [g, w]] of rr?.acc ?? []) { const v = total.get(k); if (v) { v[0] += g; v[1] += w; } else total.set(k, [g, w]); }
    rows += rr?.rows ?? 0;
    if (!done && checkpoint.bit === (bit ?? -1)) throw new Error(`slice of ${slice} bytes holds no whole block`);
    bit = checkpoint.bit; win = checkpoint.window.slice(); carry = lines.carry.slice(); steps++;
    if (done) return { total, rows, steps };
  }
}

const check = (total: Acc, prefix: RegExp) => {
  let n = 0;
  for (const [k, v] of Object.entries(cases.expect)) {
    if (!prefix.test(k)) continue;
    assertEquals(total.get(k), v, k);
    n++;
  }
  return n;
};

Deno.test("header: quoted card names with commas", () => {
  assertEquals(headerColumns('a,"deck_Arni, Humble Scribe",b\r'), ["a", "deck_Arni, Humble Scribe", "b"]);
  assertEquals(headerColumns('"say ""hi""",x'), ['say "hi"', "x"]);
});

Deno.test("pairs: two colors as written, 3C for more, C for none", () => {
  assertEquals([pairOf("UB"), pairOf("WUB"), pairOf("R"), pairOf("")], ["UB", "3C", "R", "C"]);
});

Deno.test("game data: the reference sums, read whole", async () => {
  const file = await Deno.readFile(`${T}/game.csv.gz`);
  const { total, rows, steps } = read(file, "game", file.length, 0);
  assertEquals(rows, cases.game_rows);
  assertEquals(steps, 1);
  assert(check(total, /^(T|P|D|p|pw|dc|cd|ch|cn)\|/) > 200);
  assert(check(total, /^dc\|/) > 10, "deck colors with their splashes");
  // in hand + never seen never exceeds in deck
  for (const [k, [g]] of total) {
    if (!k.startsWith("cd|")) continue;
    const rest = k.slice(3);
    assert((total.get(`ch|${rest}`)?.[0] ?? 0) + (total.get(`cn|${rest}`)?.[0] ?? 0) <= g, k);
  }
});

Deno.test("game data: the same sums in small slices with checkpoints", async () => {
  const file = await Deno.readFile(`${T}/game.csv.gz`);
  const whole = read(file, "game", file.length, 0).total;
  const sliced = read(file, "game", 5000, 2500);
  assert(sliced.steps > 3, `${sliced.steps} steps`);
  assertEquals(sliced.rows, cases.game_rows);
  assertEquals(new Map([...sliced.total].sort()), new Map([...whole].sort()));
});

Deno.test("draft data: two gzip members, read whole and in slices; picks counted with their position", async () => {
  const file = await Deno.readFile(`${T}/draft.csv.gz`);
  const whole = read(file, "draft", file.length, 0);
  assertEquals(whole.rows, cases.draft_rows, "both members read");
  assert(check(whole.total, /^a\|/) > 50);
  const sliced = read(file, "draft", 5000, 2500);
  assertEquals(sliced.rows, cases.draft_rows);
  assertEquals(new Map([...sliced.total].sort()), new Map([...whole.total].sort()));
});

Deno.test("a short or broken line is skipped", () => {
  const r = new Rows({ kind: "game", cols: ["won", "main_colors", "deck_X"] }, released);
  r.line(new TextEncoder().encode("True,UB"));
  r.line(new TextEncoder().encode(""));
  assertEquals(r.rows, 0);
  r.line(new TextEncoder().encode("True,UB,1"));
  assertEquals(r.rows, 1);
  assertEquals(r.acc.get("cd|X|a"), [1, 1]);
});
