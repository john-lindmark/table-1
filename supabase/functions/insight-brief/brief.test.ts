import { assert, assertEquals } from "jsr:@std/assert@1";
import { briefFor, clean, factsHash, problems, prompt, write, type Ask, type Facts } from "./brief.ts";

const facts: Facts = {
  view: "constructed:modern:all:30", title: "Modern metagame, last 30 days, all events",
  lines: ["Window: the last 30 days, 1,594 decks from 51 events", "Boros Energy: 21% (was 19%, +2.0 pts)", "Rising card: Blood Moon in 16% of decks (was 6.1%)"],
  thin: false,
};
const fixed = (...answers: unknown[]): Ask => {
  let i = 0;
  return async () => ({ raw: answers[Math.min(i++, answers.length - 1)], model: "claude-haiku-5-5", refused: false });
};

Deno.test("clean: sentences joined, each ending in a stop", () => {
  assertEquals(clean({ sentences: ["Boros Energy leads", "  Blood Moon is rising.  "] }), "Boros Energy leads. Blood Moon is rising.");
  assertEquals(clean({ sentences: [] }), null);
  assertEquals(clean({ brief: "x" }), null);
  assertEquals(clean(null), null);
});

Deno.test("problems: numbers must come from the facts", () => {
  assertEquals(problems("Boros Energy holds 21% of top finishes, up 2.0 pts. Blood Moon is in 16% of decks.", facts), null);
  assertEquals(problems("Across 1,594 decks Boros Energy leads at 21%. Blood Moon rose from 6.1% to 16%.", facts), null, "thousands separators");
  assert(problems("Boros Energy holds 23% of top finishes. Blood Moon is rising.", facts)!.includes("23"));
  assert(problems("Boros Energy leads by 2 points. Blood Moon rises.", facts)!.includes(": 2."), "2 is not 2.0");
});

Deno.test("problems: 2–3 sentences, 60 words, plain, no people, thin said out loud", () => {
  assert(problems("Boros Energy leads.", facts)!.includes("2 or 3 sentences"));
  assert(problems("One. Two. Three. Four.", facts)!.includes("this has 4"));
  const long = Array(70).fill("word").join(" ");
  assert(problems(`${long}. Second sentence here.`, facts)!.includes("60 words"));
  assert(problems("**Boros** leads. It is strong.", facts)!.includes("markdown"));
  assert(problems("She plays Boros. It is strong.", facts)!.includes("people"));
  const thin = { ...facts, thin: true };
  assert(problems("Boros Energy leads. Blood Moon rises.", thin)!.includes("thin"));
  assertEquals(problems("Boros Energy leads on few events. Blood Moon rises.", thin), null);
});

Deno.test("prompt says whether the sample is thin and lists the facts", () => {
  const p = prompt({ ...facts, thin: true });
  assert(p.includes("thin (few events or games)"));
  assert(p.includes("- Boros Energy: 21%"));
});

Deno.test("write: a failing brief goes back once; a second failure gives nothing", async () => {
  const good = { sentences: ["Boros Energy holds 21% of top finishes.", "Blood Moon is in 16% of decks."] };
  const bad = { sentences: ["Boros Energy holds 44%.", "Blood Moon is everywhere."] };
  assertEquals((await write(facts, fixed(good))).brief, "Boros Energy holds 21% of top finishes. Blood Moon is in 16% of decks.");
  const fixedOnce = await write(facts, fixed(bad, good));
  assertEquals(fixedOnce.rewritten, true);
  assert(fixedOnce.brief);
  assertEquals((await write(facts, fixed(bad, bad))).brief, null);
  assertEquals((await write(facts, async () => ({ raw: null, model: "m", refused: true }))).brief, null);
});

Deno.test("briefFor: cached while the facts hold, kept when a rewrite fails, none without facts", async () => {
  const store = new Map<string, { facts_hash: string; brief: string }>();
  let calls = 0;
  const rpc = async <T>(fn: string, a: Record<string, unknown>): Promise<T> => {
    if (fn === "insight_brief_get") return (store.get(a.p_view as string) ?? null) as T;
    store.set(a.p_view as string, { facts_hash: a.p_hash as string, brief: a.p_brief as string });
    return null as T;
  };
  const good = { sentences: ["Boros Energy holds 21% of top finishes.", "Blood Moon is in 16% of decks."] };
  const counting: Ask = async () => { calls++; return { raw: good, model: "m", refused: false }; };
  const b1 = await briefFor(facts, rpc, counting);
  const b2 = await briefFor(facts, rpc, counting);
  assertEquals(b1, b2);
  assertEquals(calls, 1, "the second read is the cache");
  const changed = { ...facts, lines: [...facts.lines, "Biggest drop: Izzet Prowess -2.4 pts"] };
  assert(await factsHash(changed) !== await factsHash(facts));
  assertEquals(await briefFor(changed, rpc, fixed({ sentences: ["Nonsense 77%.", "More 88%."] })), b1, "a failed rewrite keeps the old brief");
  assertEquals(await briefFor({ ...facts, view: "empty", lines: [] }, rpc, counting), null);
  assertEquals(await briefFor(facts, rpc, async () => { throw new Error("down"); }), b1);
});
