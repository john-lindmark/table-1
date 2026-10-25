import { assert, assertEquals } from "jsr:@std/assert@1";
import { problems } from "../insight-brief/brief.ts";
import { archetypeFacts, assemble, banFacts, changeWords, day, pct, pts, settledDays, windowFacts } from "./pack.ts";
import type { ConstructedPack } from "./types.ts";

const modern = JSON.parse(await Deno.readTextFile("../../testdata/insights/constructed-modern.json")) as ConstructedPack;

Deno.test("numbers as briefs write them", () => {
  assertEquals(pct(0.214), "21%");
  assertEquals(pct(0.034), "3.4%");
  assertEquals(pct(0), "0%");
  assertEquals(pts(0.061), "+6.1 pts");
  assertEquals(pts(-0.12), "-12 pts");
  assertEquals(pts(0), "+0.0 pts");
  assertEquals(day("2026-05-18"), "May 18");
});

Deno.test("settled: the first day every line holds within 2 points for 7 days", () => {
  const flat = Array(10).fill(0.2);
  assertEquals(settledDays([{ v: flat }]), 0);
  const moving = [0.3, 0.25, 0.2, 0.15, 0.12, 0.11, 0.11, 0.11, 0.12, 0.11, 0.11, 0.11, 0.12];
  assertEquals(settledDays([{ v: moving }, { v: Array(13).fill(0.1) }]), 4);
  assertEquals(settledDays([{ v: [0.3, 0.2, 0.1, 0.3, 0.2, 0.1, 0.3] }]), null);
  assertEquals(settledDays([{ v: [0.1, 0.1, 0.1] }]), null, "not enough days yet");
  assertEquals(settledDays([{ v: [null, 0.1, 0.1, 0.1, 0.1, 0.1, 0.1] }]), 0, "one missing day is fine");
});

Deno.test("assemble: briefs empty until written, daily rolled into settled_days and dropped", () => {
  const p = assemble({ ...modern, default_tier: "big" }, modern.tiers, [{
    change: 1, on: "2026-05-18", before: [{ a: 1, share: 0.2 }], after: {}, after_days: 30, losers: [], gainers: [], replacements: [], settled_days: null, brief: null,
    daily: { from: "2026-05-18", lines: [{ a: 1, v: Array(9).fill(0.1) }] },
  }, {
    change: 2, on: "2025-11-10", before: [], after: { "14": [] }, losers: [], gainers: [], replacements: [], settled_days: null, brief: null,
  }], modern.matchups, "2026-10-25T00:00:00Z");
  assertEquals(p.bans.length, 1, "a change with no data either side is left out");
  assertEquals(p.bans[0].settled_days, 0);
  assertEquals("daily" in p.bans[0], false);
  assertEquals("after_days" in p.bans[0], false);
  assertEquals(p.kind, "constructed");
});

Deno.test("window facts: top decks with their change, movers, cards, thin flag", () => {
  const w = modern.tiers.all.windows["30"];
  const f = windowFacts(modern, "all", 30, w);
  assertEquals(f.view, "constructed:modern:all:30");
  assert(f.lines[0].includes(`${w.decks} decks`));
  const top = modern.archetypes.find((a) => a.id === w.share.find((s) => s.a !== 0)!.a)!;
  assert(f.lines[1].startsWith(`${top.name}: `));
  assert(f.lines.some((l) => l.startsWith("Rising card: ")));
  assertEquals(f.thin, w.thin);
  // a brief quoting the facts' own numbers passes; an invented number doesn't
  const share = f.lines[1].match(/\d+(\.\d+)?%/)![0];
  assertEquals(problems(`${top.name} leads at ${share}. Others trail behind it.`, f), null);
  assert(problems(`${top.name} leads at 99.9%. Others trail behind it.`, f)!.includes("99.9"));
});

Deno.test("change words", () => {
  assertEquals(changeWords({ id: 1, on: "2026-05-18", kind: "ban", cards: ["A", "B"], set_code: null, note: null, url: null }), "Banned: A and B");
  assertEquals(changeWords({ id: 1, on: "2026-05-18", kind: "unban", cards: ["A", "B", "C", "D"], set_code: null, note: null, url: null }), "Unbanned: A, B, C and others");
  assertEquals(changeWords({ id: 1, on: "2026-10-02", kind: "set_release", cards: [], set_code: "fra", note: "Reality Fracture", url: null }), "Released: Reality Fracture");
});

Deno.test("ban facts name the change, the moves and whether it settled", () => {
  const ch = modern.changes.find((c) => c.kind === "ban")!;
  const f = banFacts(modern, {
    change: ch.id, on: ch.on, before: [{ a: 1, share: 0.2 }], after: { "30": [{ a: 1, share: 0.1 }] },
    losers: [{ a: modern.archetypes[1].id, before: 0.27, after: 0.09 }], gainers: [{ a: modern.archetypes[2].id, before: 0.08, after: 0.15 }],
    replacements: [{ c: "x", n: "Some Card", before: 0.02, after: 0.41, in: modern.archetypes[1].id }], settled_days: 19, brief: null,
  })!;
  assert(f.lines[0].startsWith("Banned: "));
  assert(f.lines.some((l) => l.includes("from 27% to 9.0%")));
  assert(f.lines.some((l) => l.includes("+7.0 pts")));
  assert(f.lines.includes("The shares settled after 19 days"));
  assertEquals(f.thin, false);
  assertEquals(banFacts(modern, { change: -1 } as never), null);
});

Deno.test("archetype facts: record only with 20+ matches, matchups only with 30+", () => {
  const a = modern.archetypes[1];
  const f = archetypeFacts(modern, {
    archetype: a, decks: 40, record: { wins: 12, losses: 6, basis: "mtgo_top32" }, conv: null,
    core: [{ n: "A" }, { n: "B" }], flex: [{ n: "C", rate: 0.5 }], side: [{ n: "D", rate: 0.3 }],
    matchups: [{ vs: 0, wins: 20, losses: 15, draws: 0 }, { vs: 0, wins: 5, losses: 5, draws: 0 }],
  }, { share: 0.12, prev: 0.1 });
  assertEquals(f.view, `arch:modern:${a.id}`);
  assert(!f.lines.some((l) => l.startsWith("Match record")), "18 matches is too few to quote");
  assertEquals(f.lines.filter((l) => l.startsWith("Against ")).length, 1);
  assert(f.lines.includes("Core cards: A, B"));
});
